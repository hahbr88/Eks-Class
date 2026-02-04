#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# 기본값: 사용자 제공 VPC 2개
VPCS_DEFAULT=("vpc-07758b48139f81a02" "vpc-0f871ce4d93d12962")

# 옵션
MODE="${1:---plan}"                 # --plan | --apply
SHIFT_VPCS="${2:-}"                 # optional: "vpc-xxx,vpc-yyy"
DELETE_VPC="${DELETE_VPC:-true}"    # true|false (VPC 자체 삭제 여부)
DELETE_CFN="${DELETE_CFN:-true}"    # true|false (CloudFormation 스택 삭제 여부)
DELETE_EKS="${DELETE_EKS:-true}"    # true|false (EKS 삭제 여부)
SKIP_CFN_PATTERNS="${SKIP_CFN_PATTERNS:-}" # e.g. "DoNotDelete,prod,shared"

AWS="aws --profile ${AWS_PROFILE} --region ${AWS_REGION}"

# =========================
# Helpers
# =========================
log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }
die() { echo -e "\n[ERROR] $*" >&2; exit 1; }

get_ids() { tr '\t' '\n' | sed '/^$/d'; }

is_true() {
  [[ "${1,,}" == "true" || "${1,,}" == "1" || "${1,,}" == "yes" ]]
}

run_or_echo() {
  # $1: command string
  if [[ "$MODE" == "--plan" ]]; then
    echo "PLAN: $1"
  else
    eval "$1"
  fi
}

require_aws() {
  command -v aws >/dev/null 2>&1 || die "aws CLI not found"
  $AWS sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials/permission issue (sts get-caller-identity failed)"
}

# =========================
# Input VPCs
# =========================
VPCS=("${VPCS_DEFAULT[@]}")
if [[ -n "$SHIFT_VPCS" ]]; then
  IFS=',' read -r -a VPCS <<< "$SHIFT_VPCS"
fi

# =========================
# EKS discovery by VPC
# =========================
discover_eks_clusters_for_vpc() {
  local vpc="$1"
  local clusters all
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
  ngs="$(echo "$ngs" | get_ids || true)"
  if [[ -n "$ngs" ]]; then
    for ng in $ngs; do
      run_or_echo "$AWS eks delete-nodegroup --cluster-name \"$cluster\" --nodegroup-name \"$ng\" >/dev/null"
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
  fps="$(echo "$fps" | get_ids || true)"
  if [[ -n "$fps" ]]; then
    for fp in $fps; do
      run_or_echo "$AWS eks delete-fargate-profile --cluster-name \"$cluster\" --fargate-profile-name \"$fp\" >/dev/null"
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
  adds="$(echo "$adds" | get_ids || true)"
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
  run_or_echo "$AWS eks delete-cluster --name \"$cluster\" >/dev/null"
  if [[ "$MODE" == "--apply" ]]; then
    $AWS eks wait cluster-deleted --name "$cluster" || true
  fi
}

# =========================
# CloudFormation (find stacks referencing VPC)
# =========================
list_active_stacks() {
  $AWS cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE IMPORT_COMPLETE \
    --query "StackSummaries[].StackName" --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
}

stack_mentions_vpc() {
  local stack="$1"
  local vpc="$2"
  # describe-stacks text output에 vpc-id 포함 여부로 빠르게 필터
  $AWS cloudformation describe-stacks --stack-name "$stack" --output text 2>/dev/null | grep -q "$vpc"
}

should_skip_stack_by_pattern() {
  local stack="$1"
  if [[ -z "$SKIP_CFN_PATTERNS" ]]; then return 1; fi
  IFS=',' read -r -a pats <<< "$SKIP_CFN_PATTERNS"
  for p in "${pats[@]}"; do
    [[ -n "$p" ]] && echo "$stack" | grep -qi "$p" && return 0
  done
  return 1
}

rank_stack_child_first() {
  # 휴리스틱 정렬 키: 숫자 낮을수록 먼저 삭제(더 하위)
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
    if stack_mentions_vpc "$s" "$vpc"; then
      if should_skip_stack_by_pattern "$s"; then
        warn "Skip stack by pattern: $s"
      else
        candidates+="$s"$'\n'
      fi
    fi
  done <<< "$stacks"

  candidates="$(echo "$candidates" | sed '/^$/d' || true)"
  if [[ -z "$candidates" ]]; then
    echo "  (no stacks found for $vpc)"
    return
  fi

  sorted="$(while read -r s; do rank_stack_child_first "$s"; done <<< "$candidates" | sort -n | cut -d' ' -f2-)"
  log "Stacks to delete (child-first heuristic):"
  echo "$sorted"

  if [[ "$MODE" == "--plan" ]]; then
    echo "PLAN: would delete stacks above"
    return
  fi

  # delete
  while read -r s; do
    [[ -z "$s" ]] && continue
    echo "Delete stack: $s"
    $AWS cloudformation delete-stack --stack-name "$s" || true
  done <<< "$sorted"

  # wait
  while read -r s; do
    [[ -z "$s" ]] && continue
    echo "Wait delete complete: $s"
    $AWS cloudformation wait stack-delete-complete --stack-name "$s" 2>/dev/null || true
  done <<< "$sorted"

  warn "If any stack becomes DELETE_FAILED, inspect:"
  echo "  aws --profile $AWS_PROFILE --region $AWS_REGION cloudformation describe-stack-events --stack-name <STACK> \\"
  echo "    --query \"StackEvents[0:15].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]\" --output table"
}

# =========================
# VPC teardown (bottom-up)
# =========================
delete_vpc_endpoints() {
  local vpc="$1"
  log "VPC endpoints delete: $vpc"
  local eps
  eps="$($AWS ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpc" \
    --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)"
  eps="$(echo "$eps" | get_ids || true)"
  [[ -z "$eps" ]] && { echo "  (none)"; return; }
  run_or_echo "$AWS ec2 delete-vpc-endpoints --vpc-endpoint-ids $eps >/dev/null"
}

delete_nat_gateways() {
  local vpc="$1"
  log "NAT gateways delete: $vpc"
  local ngws
  ngws="$($AWS ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)"
  ngws="$(echo "$ngws" | get_ids || true)"
  [[ -z "$ngws" ]] && { echo "  (none)"; return; }

  for ngw in $ngws; do
    run_or_echo "$AWS ec2 delete-nat-gateway --nat-gateway-id \"$ngw\" >/dev/null || true"
  done

  if [[ "$MODE" == "--apply" ]]; then
    warn "Waiting NAT gateways to be deleted (polling)..."
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
  local igws
  igws="$($AWS ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" \
    --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || true)"
  igws="$(echo "$igws" | get_ids || true)"
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
  rtbs="$(echo "$rtbs" | get_ids || true)"
  [[ -z "$rtbs" ]] && { echo "  (none)"; return; }

  for rtb in $rtbs; do
    local assoc is_main
    assoc="$($AWS ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text 2>/dev/null || true)"
    assoc="$(echo "$assoc" | get_ids || true)"
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

delete_subnets() {
  local vpc="$1"
  log "Subnets delete: $vpc"
  local subs
  subs="$($AWS ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" \
    --query "Subnets[].SubnetId" --output text 2>/dev/null || true)"
  subs="$(echo "$subs" | get_ids || true)"
  [[ -z "$subs" ]] && { echo "  (none)"; return; }

  for s in $subs; do
    run_or_echo "$AWS ec2 delete-subnet --subnet-id \"$s\" >/dev/null || true"
  done
}

delete_network_acls() {
  local vpc="$1"
  log "Network ACLs delete (skip default): $vpc"
  local nacls
  nacls="$($AWS ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpc" \
    --query "NetworkAcls[?IsDefault==\`false\`].NetworkAclId" --output text 2>/dev/null || true)"
  nacls="$(echo "$nacls" | get_ids || true)"
  [[ -z "$nacls" ]] && { echo "  (none)"; return; }

  for n in $nacls; do
    run_or_echo "$AWS ec2 delete-network-acl --network-acl-id \"$n\" >/dev/null || true"
  done
}

delete_security_groups() {
  local vpc="$1"
  log "Security groups delete (skip default): $vpc"
  local sgs
  sgs="$($AWS ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)"
  sgs="$(echo "$sgs" | get_ids || true)"
  [[ -z "$sgs" ]] && { echo "  (none)"; return; }

  for sg in $sgs; do
    run_or_echo "$AWS ec2 delete-security-group --group-id \"$sg\" >/dev/null || true"
  done
}

delete_vpc_itself() {
  local vpc="$1"
  log "VPC delete: $vpc"
  run_or_echo "$AWS ec2 delete-vpc --vpc-id \"$vpc\" >/dev/null"
}

# Optional: show remaining ENIs if delete fails
show_enis() {
  local vpc="$1"
  warn "If deletion fails, inspect ENIs still in VPC:"
  echo "  $AWS ec2 describe-network-interfaces --filters Name=vpc-id,Values=$vpc \\"
  echo "    --query \"NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description,Att:Attachment.InstanceId,SGs:Groups[].GroupId}\" --output table"
}

# =========================
# Main flow per VPC
# =========================
process_vpc() {
  local vpc="$1"

  log "=============================="
  log "PROCESS VPC: $vpc"
  log "MODE=$MODE | profile=$AWS_PROFILE | region=$AWS_REGION"
  log "DELETE_EKS=$DELETE_EKS | DELETE_CFN=$DELETE_CFN | DELETE_VPC=$DELETE_VPC"
  log "=============================="

  # 1) EKS delete
  if is_true "$DELETE_EKS"; then
    log "Discover EKS clusters for VPC: $vpc"
    local clusters
    clusters="$(discover_eks_clusters_for_vpc "$vpc" || true)"
    if [[ -z "$clusters" ]]; then
      echo "  (no EKS clusters found)"
    else
      echo "$clusters" | sed 's/^/  - /'
      while read -r c; do
        [[ -z "$c" ]] && continue
        delete_eks_cluster_full "$c"
      done <<< "$clusters"
    fi
  else
    warn "Skip EKS deletion by DELETE_EKS=false"
  fi

  # 2) CloudFormation delete
  if is_true "$DELETE_CFN"; then
    delete_cfn_stacks_for_vpc "$vpc"
  else
    warn "Skip CloudFormation deletion by DELETE_CFN=false"
  fi

  # 3) VPC bottom-up teardown
  log "VPC bottom-up teardown start: $vpc"
  delete_vpc_endpoints "$vpc"
  delete_nat_gateways "$vpc"
  detach_delete_igw "$vpc"
  delete_route_tables "$vpc"
  delete_subnets "$vpc"
  delete_network_acls "$vpc"
  delete_security_groups "$vpc"

  # 4) VPC delete
  if is_true "$DELETE_VPC"; then
    delete_vpc_itself "$vpc"
  else
    warn "Skip VPC delete by DELETE_VPC=false"
  fi

  show_enis "$vpc"
}

# =========================
# Run
# =========================
require_aws

if [[ "$MODE" != "--plan" && "$MODE" != "--apply" ]]; then
  die "Usage: $0 --plan|--apply [vpc-aaa,vpc-bbb]"
fi

log "Target VPCs:"
printf ' - %s\n' "${VPCS[@]}"

if [[ "$MODE" == "--apply" ]]; then
  warn "DANGER: This will DELETE resources. Review with --plan first."
fi

for vpc in "${VPCS[@]}"; do
  process_vpc "$vpc"
done

log "DONE"
