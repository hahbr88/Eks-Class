#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# EKS + CloudFormation + VPC Bottom-up Teardown (final)
#
# Features
# - VPC 기준으로 EKS 클러스터 자동 탐지/삭제 (nodegroups/fargate/addons/cluster)
# - CloudFormation 스택 VPC 연관 자동 탐지/삭제
#   - TerminationProtection=true 스택은 기본 스킵(안전)
#   - 옵션으로 TP 해제 후 삭제 가능
#   - eksctl-*-cluster 스택은 기본 스킵(안전)
#   - 옵션으로 클러스터 스택 삭제 가능
# - ALB/NLB(ELBv2) / VPC Endpoints(특히 Interface) 조기 삭제로 ENI/SG 의존성 완화
# - IGW detach 실패 원인(EIP mapped public addresses) 자동 unmap + (옵션) release
# - Subnet/SG 삭제 실패 시 의존 ENI 자동 출력
# - 여러 번 Sweep(재시도)로 AWS 내부 detach 지연 대응
#
# Usage
#   ./teardown.sh --plan
#   ./teardown.sh --apply
#   ./teardown.sh --apply "vpc-aaa,vpc-bbb"
#
# Environment overrides
#   AWS_PROFILE=default AWS_REGION=ap-northeast-2 ./teardown.sh --plan
# ============================================================

# -------------------------
# Basic config
# -------------------------
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
AWS="aws --profile ${AWS_PROFILE} --region ${AWS_REGION}"

MODE="${1:---plan}"            # --plan | --apply
SHIFT_VPCS="${2:-}"            # optional: "vpc-aaa,vpc-bbb"

# Defaults (your VPCs)
VPCS_DEFAULT=("vpc-07758b48139f81a02" "vpc-0f871ce4d93d12962")
VPCS=("${VPCS_DEFAULT[@]}")
if [[ -n "$SHIFT_VPCS" ]]; then
  IFS=',' read -r -a VPCS <<< "$SHIFT_VPCS"
fi

# -------------------------
# Toggles
# -------------------------
DELETE_EKS="${DELETE_EKS:-true}"
DELETE_CFN="${DELETE_CFN:-true}"
DELETE_VPC="${DELETE_VPC:-true}"

DELETE_ELB="${DELETE_ELB:-true}"     # delete ALB/NLB (ELBv2) early
DELETE_VPCE="${DELETE_VPCE:-true}"   # delete VPC endpoints early

# IGW/EIP handling
UNMAP_EIP_BEFORE_IGW="${UNMAP_EIP_BEFORE_IGW:-true}"      # disassociate EIP mapped to ENI
RELEASE_EIP_BEFORE_IGW="${RELEASE_EIP_BEFORE_IGW:-true}"  # release EIP allocations after disassociate

# CloudFormation safety
# - Default: do NOT delete eksctl-*-cluster stack unless enabled (prevents accidental cluster teardown)
DELETE_CLUSTER_STACK="${DELETE_CLUSTER_STACK:-false}"

# - Default: do NOT auto disable termination protection unless enabled
DISABLE_TP_ON_DELETE="${DISABLE_TP_ON_DELETE:-false}"

# CFN exclusions
SKIP_CFN_PATTERNS="${SKIP_CFN_PATTERNS:-}"  # e.g. "prod,shared,DoNotDelete"
SKIP_CFN_STACKS="${SKIP_CFN_STACKS:-eksctl-eksdemo1-cluster}"  # explicit stack names to skip

# Sweep control
MAX_SWEEPS="${MAX_SWEEPS:-8}"
SLEEP_BETWEEN_SWEEPS_SEC="${SLEEP_BETWEEN_SWEEPS_SEC:-12}"

# -------------------------
# Logging
# -------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log()  { echo -e "\n[$(ts)] [INFO] $*"; }
warn() { echo -e "\n[$(ts)] [WARN] $*"; }
err()  { echo -e "\n[$(ts)] [ERROR] $*" >&2; }

die() { err "$*"; exit 1; }

is_true() {
  [[ "${1,,}" == "true" || "${1,,}" == "1" || "${1,,}" == "yes" ]]
}

run_or_echo() {
  if [[ "$MODE" == "--plan" ]]; then
    echo "PLAN: $*"
  else
    eval "$*"
  fi
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found"
  $AWS sts get-caller-identity >/dev/null 2>&1 || die "AWS auth failed (sts get-caller-identity)"
}

tab2lines() { tr '\t' '\n' | sed '/^$/d'; }

# ============================================================
# Diagnostics helpers
# ============================================================
show_enis_in_subnet() {
  local subnet="$1"
  $AWS ec2 describe-network-interfaces \
    --filters Name=subnet-id,Values="$subnet" \
    --query "NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description,Req:RequesterId,Att:Attachment.InstanceId,IFType:InterfaceType,SGs:Groups[].GroupId,PublicIp:Association.PublicIp}" \
    --output table 2>/dev/null || true
}

show_enis_using_sg() {
  local sg="$1"
  $AWS ec2 describe-network-interfaces \
    --filters Name=group-id,Values="$sg" \
    --query "NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description,Req:RequesterId,Att:Attachment.InstanceId,IFType:InterfaceType,Subnet:SubnetId,PublicIp:Association.PublicIp}" \
    --output table 2>/dev/null || true
}

show_enis_in_vpc_hint() {
  local vpc="$1"
  warn "If still blocked, list ENIs in VPC:"
  echo "  $AWS ec2 describe-network-interfaces --filters Name=vpc-id,Values=$vpc \\"
  echo "    --query \"NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description,Req:RequesterId,Att:Attachment.InstanceId,Subnet:SubnetId,SGs:Groups[].GroupId,PublicIp:Association.PublicIp}\" --output table"
}

# ============================================================
# EIP / IGW handling
# ============================================================
unmap_public_addresses_in_vpc() {
  local vpc="$1"
  log "Unmap public addresses (EIP associations) in VPC: $vpc"

  local assoc_ids
  assoc_ids="$($AWS ec2 describe-network-interfaces \
    --filters Name=vpc-id,Values=$vpc \
    --query "NetworkInterfaces[?Association.AssociationId!=null].Association.AssociationId" \
    --output text 2>/dev/null || true)"
  assoc_ids="$(echo "$assoc_ids" | tab2lines || true)"

  [[ -z "$assoc_ids" ]] && { echo "  (no public address associations)"; return; }

  for a in $assoc_ids; do
    run_or_echo "$AWS ec2 disassociate-address --association-id \"$a\" >/dev/null || true"
  done
}

release_eips_in_vpc() {
  local vpc="$1"
  log "Release EIPs still associated to ENIs in VPC: $vpc"

  local alloc_ids
  alloc_ids="$($AWS ec2 describe-network-interfaces \
    --filters Name=vpc-id,Values=$vpc \
    --query "NetworkInterfaces[?Association.AllocationId!=null].Association.AllocationId" \
    --output text 2>/dev/null || true)"
  alloc_ids="$(echo "$alloc_ids" | tab2lines || true)"

  [[ -z "$alloc_ids" ]] && { echo "  (no EIP allocations on ENIs)"; return; }

  for alloc in $alloc_ids; do
    run_or_echo "$AWS ec2 release-address --allocation-id \"$alloc\" >/dev/null || true"
  done
}

# ============================================================
# EKS discovery & deletion
# ============================================================
discover_eks_clusters_for_vpc() {
  local vpc="$1"
  local all clusters
  all="$($AWS eks list-clusters --query "clusters[]" --output text 2>/dev/null || true)"
  clusters=""
  for c in $all; do
    local cvpc
    cvpc="$($AWS eks describe-cluster --name "$c" --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)"
    if [[ "$cvpc" == "$vpc" ]]; then
      clusters+="$c"$'\n'
    fi
  done
  echo "$clusters" | sed '/^$/d'
}

delete_eks_cluster_full() {
  local cluster="$1"
  log "EKS delete: $cluster (nodegroups -> fargate -> addons -> cluster)"

  # nodegroups
  local ngs
  ngs="$($AWS eks list-nodegroups --cluster-name "$cluster" --query 'nodegroups[]' --output text 2>/dev/null || true)"
  ngs="$(echo "$ngs" | tab2lines || true)"
  if [[ -n "$ngs" ]]; then
    for ng in $ngs; do
      run_or_echo "$AWS eks delete-nodegroup --cluster-name \"$cluster\" --nodegroup-name \"$ng\" >/dev/null || true"
      if [[ "$MODE" == "--apply" ]]; then
        $AWS eks wait nodegroup-deleted --cluster-name "$cluster" --nodegroup-name "$ng" || true
      fi
    done
  else
    echo "  (no nodegroups)"
  fi

  # fargate profiles
  local fps
  fps="$($AWS eks list-fargate-profiles --cluster-name "$cluster" --query 'fargateProfileNames[]' --output text 2>/dev/null || true)"
  fps="$(echo "$fps" | tab2lines || true)"
  if [[ -n "$fps" ]]; then
    for fp in $fps; do
      run_or_echo "$AWS eks delete-fargate-profile --cluster-name \"$cluster\" --fargate-profile-name \"$fp\" >/dev/null || true"
      if [[ "$MODE" == "--apply" ]]; then
        $AWS eks wait fargate-profile-deleted --cluster-name "$cluster" --fargate-profile-name "$fp" || true
      fi
    done
  else
    echo "  (no fargate profiles)"
  fi

  # addons
  local adds
  adds="$($AWS eks list-addons --cluster-name "$cluster" --query 'addons[]' --output text 2>/dev/null || true)"
  adds="$(echo "$adds" | tab2lines || true)"
  if [[ -n "$adds" ]]; then
    for a in $adds; do
      run_or_echo "$AWS eks delete-addon --cluster-name \"$cluster\" --addon-name \"$a\" >/dev/null || true"
      if [[ "$MODE" == "--apply" ]]; then
        $AWS eks wait addon-deleted --cluster-name "$cluster" --addon-name "$a" 2>/dev/null || true
      fi
    done
  else
    echo "  (no addons)"
  fi

  # cluster
  run_or_echo "$AWS eks delete-cluster --name \"$cluster\" >/dev/null || true"
  if [[ "$MODE" == "--apply" ]]; then
    $AWS eks wait cluster-deleted --name "$cluster" || true
  fi
}

# ============================================================
# ELBv2 deletion (releases ENIs/SGs)
# ============================================================
delete_elbv2_in_vpc() {
  local vpc="$1"
  log "ELBv2 delete in VPC (ALB/NLB): $vpc"
  local arns
  arns="$($AWS elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerArn" --output text 2>/dev/null || true)"
  arns="$(echo "$arns" | tab2lines || true)"
  [[ -z "$arns" ]] && { echo "  (none)"; return; }

  for arn in $arns; do
    run_or_echo "$AWS elbv2 delete-load-balancer --load-balancer-arn \"$arn\" >/dev/null || true"
  done
}

# ============================================================
# VPC Endpoint deletion (Interface endpoints create ENIs & SG deps)
# ============================================================
delete_vpc_endpoints() {
  local vpc="$1"
  log "VPC endpoints delete: $vpc"
  local eps
  eps="$($AWS ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" \
    --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
  eps="$(echo "$eps" | tab2lines || true)"
  [[ -z "$eps" ]] && { echo "  (none)"; return; }

  run_or_echo "$AWS ec2 delete-vpc-endpoints --vpc-endpoint-ids $eps >/dev/null || true"
}

# ============================================================
# CloudFormation deletion
# ============================================================
list_active_stacks() {
  $AWS cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE IMPORT_COMPLETE \
    --query "StackSummaries[].StackName" --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

stack_mentions_vpc() {
  local stack="$1"
  local vpc="$2"
  $AWS cloudformation describe-stacks --stack-name "$stack" --output text 2>/dev/null | grep -q "$vpc"
}

stack_termination_protection_enabled() {
  local stack="$1"
  local tp
  tp="$($AWS cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].EnableTerminationProtection" --output text 2>/dev/null || echo "False")"
  [[ "$tp" == "True" ]]
}

disable_termination_protection() {
  local stack="$1"
  run_or_echo "$AWS cloudformation update-termination-protection --stack-name \"$stack\" --no-enable-termination-protection >/dev/null || true"
}

should_skip_stack_by_pattern() {
  local stack="$1"
  [[ -z "$SKIP_CFN_PATTERNS" ]] && return 1
  IFS=',' read -r -a pats <<< "$SKIP_CFN_PATTERNS"
  for p in "${pats[@]}"; do
    [[ -n "$p" ]] && echo "$stack" | grep -qi "$p" && return 0
  done
  return 1
}

should_skip_stack_exact() {
  local stack="$1"
  [[ -z "$SKIP_CFN_STACKS" ]] && return 1
  IFS=',' read -r -a arr <<< "$SKIP_CFN_STACKS"
  for x in "${arr[@]}"; do
    [[ -n "$x" && "$stack" == "$x" ]] && return 0
  done
  return 1
}

rank_stack_child_first() {
  local s="$1"
  if echo "$s" | grep -Eqi 'nodegroup|managednodegroup|addon|fargate|alb|ingress|lb|loadbalancer|targetgroup'; then
    echo "1 $s"
  elif echo "$s" | grep -Eqi 'eksctl|eks|cluster'; then
    echo "9 $s"
  else
    echo "5 $s"
  fi
}

delete_cfn_stacks_for_vpc() {
  local vpc="$1"
  log "CloudFormation: find stacks mentioning $vpc"

  local stacks candidates sorted
  stacks="$(list_active_stacks || true)"
  candidates=""

  while read -r s; do
    [[ -z "$s" ]] && continue
    stack_mentions_vpc "$s" "$vpc" || continue

    # explicit skip list
    if should_skip_stack_exact "$s"; then
      warn "Skip stack (explicit): $s"
      continue
    fi

    # cluster stack guard (eksctl-*-cluster)
    if echo "$s" | grep -Eq '^eksctl-.*-cluster$'; then
      if ! is_true "$DELETE_CLUSTER_STACK"; then
        warn "Skip cluster stack (DELETE_CLUSTER_STACK=false): $s"
        continue
      fi
    fi

    # termination protection guard
    if stack_termination_protection_enabled "$s"; then
      if is_true "$DISABLE_TP_ON_DELETE"; then
        warn "TerminationProtection enabled; disabling then deleting: $s"
        disable_termination_protection "$s"
      else
        warn "Skip stack (TerminationProtection enabled): $s"
        continue
      fi
    fi

    # pattern skip
    if should_skip_stack_by_pattern "$s"; then
      warn "Skip stack (pattern): $s"
      continue
    fi

    candidates+="$s"$'\n'
  done <<< "$stacks"

  candidates="$(echo "$candidates" | sed '/^$/d' || true)"
  [[ -z "$candidates" ]] && { echo "  (no stacks found)"; return; }

  sorted="$(while read -r s; do rank_stack_child_first "$s"; done <<< "$candidates" | sort -n | cut -d' ' -f2-)"
  log "Stacks to delete (child-first heuristic):"
  echo "$sorted"

  if [[ "$MODE" == "--plan" ]]; then
    echo "PLAN: would delete stacks above"
    return
  fi

  while read -r s; do
    [[ -z "$s" ]] && continue
    echo "Delete stack: $s"
    $AWS cloudformation delete-stack --stack-name "$s" || true
  done <<< "$sorted"

  while read -r s; do
    [[ -z "$s" ]] && continue
    echo "Wait delete complete: $s"
    $AWS cloudformation wait stack-delete-complete --stack-name "$s" 2>/dev/null || true
  done <<< "$sorted"

  warn "If any stack becomes DELETE_FAILED, inspect:"
  echo "  $AWS cloudformation describe-stack-events --stack-name <STACK> \\"
  echo "    --query \"StackEvents[0:15].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]\" --output table"
}

# ============================================================
# VPC teardown functions
# ============================================================
delete_nat_gateways() {
  local vpc="$1"
  log "NAT gateways delete: $vpc"
  local ngws
  ngws="$($AWS ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)"
  ngws="$(echo "$ngws" | tab2lines || true)"
  [[ -z "$ngws" ]] && { echo "  (none)"; return; }

  for ngw in $ngws; do
    run_or_echo "$AWS ec2 delete-nat-gateway --nat-gateway-id \"$ngw\" >/dev/null || true"
  done

  if [[ "$MODE" == "--apply" ]]; then
    warn "Waiting NAT gateways to become deleted..."
    for ngw in $ngws; do
      while true; do
        state="$($AWS ec2 describe-nat-gateways --nat-gateway-ids "$ngw" --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")"
        [[ "$state" == "deleted" ]] && break
        echo "  - $ngw state=$state ... waiting"
        sleep 10
      done
    done
  fi
}

detach_delete_igw() {
  local vpc="$1"
  log "Internet gateway detach+delete: $vpc"

  if is_true "$UNMAP_EIP_BEFORE_IGW"; then
    unmap_public_addresses_in_vpc "$vpc"
  fi
  if is_true "$RELEASE_EIP_BEFORE_IGW"; then
    release_eips_in_vpc "$vpc"
  fi

  local igws
  igws="$($AWS ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || true)"
  igws="$(echo "$igws" | tab2lines || true)"
  [[ -z "$igws" ]] && { echo "  (none)"; return; }

  for igw in $igws; do
    run_or_echo "$AWS ec2 detach-internet-gateway --internet-gateway-id \"$igw\" --vpc-id \"$vpc\" >/dev/null || true"
    run_or_echo "$AWS ec2 delete-internet-gateway --internet-gateway-id \"$igw\" >/dev/null || true"
  done
}

delete_route_tables() {
  local vpc="$1"
  log "Route tables disassociate+delete (skip main): $vpc"

  local rtbs
  rtbs="$($AWS ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
    --query "RouteTables[].RouteTableId" --output text 2>/dev/null || true)"
  rtbs="$(echo "$rtbs" | tab2lines || true)"
  [[ -z "$rtbs" ]] && { echo "  (none)"; return; }

  for rtb in $rtbs; do
    local assoc is_main
    assoc="$($AWS ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)"
    assoc="$(echo "$assoc" | tab2lines || true)"
    if [[ -n "$assoc" ]]; then
      for a in $assoc; do
        run_or_echo "$AWS ec2 disassociate-route-table --association-id \"$a\" >/dev/null || true"
      done
    fi

    is_main="$($AWS ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[?Main==\`true\`].Main | [0]" --output text 2>/dev/null || echo "None")"

    if [[ "$is_main" == "True" ]]; then
      echo "  - $rtb is main: skip delete"
    else
      run_or_echo "$AWS ec2 delete-route-table --route-table-id \"$rtb\" >/dev/null || true"
    fi
  done
}

delete_network_acls() {
  local vpc="$1"
  log "Network ACLs delete (skip default): $vpc"

  local nacls
  nacls="$($AWS ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc" \
    --query "NetworkAcls[?IsDefault==\`false\`].NetworkAclId" --output text 2>/dev/null || true)"
  nacls="$(echo "$nacls" | tab2lines || true)"
  [[ -z "$nacls" ]] && { echo "  (none)"; return; }

  for n in $nacls; do
    run_or_echo "$AWS ec2 delete-network-acl --network-acl-id \"$n\" >/dev/null || true"
  done
}

delete_subnets_sweep() {
  local vpc="$1"
  local deleted_any="false"

  local subs
  subs="$($AWS ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
    --query "Subnets[].SubnetId" --output text 2>/dev/null || true)"
  subs="$(echo "$subs" | tab2lines || true)"
  [[ -z "$subs" ]] && { echo "  (no subnets)"; echo "$deleted_any"; return; }

  for s in $subs; do
    if [[ "$MODE" == "--plan" ]]; then
      echo "PLAN: $AWS ec2 delete-subnet --subnet-id \"$s\""
      continue
    fi

    if $AWS ec2 delete-subnet --subnet-id "$s" >/dev/null 2>/tmp/delete_subnet_err.txt; then
      echo "Deleted subnet: $s"
      deleted_any="true"
    else
      warn "DeleteSubnet failed: $s"
      cat /tmp/delete_subnet_err.txt || true
      warn "Dependencies (ENIs) in subnet $s:"
      show_enis_in_subnet "$s"
      warn "Skip subnet for now: $s"
    fi
  done

  echo "$deleted_any"
}

delete_security_groups_sweep() {
  local vpc="$1"
  local deleted_any="false"

  local sgs
  sgs="$($AWS ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)"
  sgs="$(echo "$sgs" | tab2lines || true)"
  [[ -z "$sgs" ]] && { echo "  (no security groups)"; echo "$deleted_any"; return; }

  for sg in $sgs; do
    if [[ "$MODE" == "--plan" ]]; then
      echo "PLAN: $AWS ec2 delete-security-group --group-id \"$sg\""
      continue
    fi

    if $AWS ec2 delete-security-group --group-id "$sg" >/dev/null 2>/tmp/delete_sg_err.txt; then
      echo "Deleted SG: $sg"
      deleted_any="true"
    else
      warn "DeleteSecurityGroup failed: $sg"
      cat /tmp/delete_sg_err.txt || true
      warn "Dependencies (ENIs) using SG $sg:"
      show_enis_using_sg "$sg"
      warn "Skip SG for now: $sg"
    fi
  done

  echo "$deleted_any"
}

delete_vpc_itself() {
  local vpc="$1"
  log "VPC delete: $vpc"
  run_or_echo "$AWS ec2 delete-vpc --vpc-id \"$vpc\" >/dev/null || true"
}

# ============================================================
# Main flow per VPC
# ============================================================
process_vpc() {
  local vpc="$1"

  log "================================================"
  log "PROCESS VPC: $vpc | MODE=$MODE | profile=$AWS_PROFILE | region=$AWS_REGION"
  log "DELETE_EKS=$DELETE_EKS DELETE_CFN=$DELETE_CFN DELETE_ELB=$DELETE_ELB DELETE_VPCE=$DELETE_VPCE DELETE_VPC=$DELETE_VPC"
  log "DELETE_CLUSTER_STACK=$DELETE_CLUSTER_STACK DISABLE_TP_ON_DELETE=$DISABLE_TP_ON_DELETE"
  log "UNMAP_EIP_BEFORE_IGW=$UNMAP_EIP_BEFORE_IGW RELEASE_EIP_BEFORE_IGW=$RELEASE_EIP_BEFORE_IGW"
  log "================================================"

  # 1) EKS deletion (API level)
  if is_true "$DELETE_EKS"; then
    log "Discover EKS clusters for VPC: $vpc"
    local clusters
    clusters="$(discover_eks_clusters_for_vpc "$vpc" || true)"
    if [[ -n "$clusters" ]]; then
      echo "$clusters" | sed 's/^/  - /'
      while read -r c; do
        [[ -z "$c" ]] && continue
        delete_eks_cluster_full "$c"
      done <<< "$clusters"
    else
      echo "  (no EKS clusters found)"
    fi
  else
    warn "Skip EKS deletion (DELETE_EKS=false)"
  fi

  # 2) Early deletes to release ENIs/SG deps
  if is_true "$DELETE_ELB"; then
    delete_elbv2_in_vpc "$vpc"
  else
    warn "Skip ELBv2 deletion (DELETE_ELB=false)"
  fi

  if is_true "$DELETE_VPCE"; then
    delete_vpc_endpoints "$vpc"
  else
    warn "Skip VPC endpoint deletion (DELETE_VPCE=false)"
  fi

  # 3) CFN deletion
  if is_true "$DELETE_CFN"; then
    delete_cfn_stacks_for_vpc "$vpc"
  else
    warn "Skip CloudFormation deletion (DELETE_CFN=false)"
  fi

  # 4) Core networking teardown
  delete_nat_gateways "$vpc"
  detach_delete_igw "$vpc"
  delete_route_tables "$vpc"

  # 5) Sweeps: subnets & SGs often unblock gradually
  for i in $(seq 1 "$MAX_SWEEPS"); do
    log "SWEEP $i/$MAX_SWEEPS: attempt subnet/SG deletion"
    local sub_deleted sg_deleted

    sub_deleted="$(delete_subnets_sweep "$vpc" || echo "false")"
    delete_network_acls "$vpc"
    sg_deleted="$(delete_security_groups_sweep "$vpc" || echo "false")"

    if [[ "$MODE" == "--plan" ]]; then
      break
    fi

    if [[ "$sub_deleted" != "true" && "$sg_deleted" != "true" ]]; then
      echo "No progress in this sweep."
      echo "Sleep ${SLEEP_BETWEEN_SWEEPS_SEC}s..."
      sleep "$SLEEP_BETWEEN_SWEEPS_SEC"
    fi
  done

  # 6) Finally delete VPC
  if is_true "$DELETE_VPC"; then
    delete_vpc_itself "$vpc"
  else
    warn "Skip VPC delete (DELETE_VPC=false)"
  fi

  show_enis_in_vpc_hint "$vpc"
}

# ============================================================
# Entry
# ============================================================
require_aws
[[ "$MODE" == "--plan" || "$MODE" == "--apply" ]] || die "Usage: $0 --plan|--apply [vpc-aaa,vpc-bbb]"

log "Target VPCs:"
printf ' - %s\n' "${VPCS[@]}"

if [[ "$MODE" == "--apply" ]]; then
  warn "DANGER: This will DELETE resources. Run --plan first."
fi

for vpc in "${VPCS[@]}"; do
  process_vpc "$vpc"
done

log "DONE"
