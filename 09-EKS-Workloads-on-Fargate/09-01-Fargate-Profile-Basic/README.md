# EKS Fargate 프로파일 - 기본

## 단계-01: 무엇을 학습하나요?
- **가정 사항:**
  - eksctl로 생성한 **eksdemo1** EKS 클러스터가 이미 존재합니다.
  - 프라이빗 네트워킹이 활성화된 워커 노드 2개를 가진 관리형 노드 그룹이 있습니다.
- 기존 EKS 클러스터 eksdemo1에 `eksctl`로 Fargate 프로파일을 생성합니다.
- 간단한 워크로드를 배포합니다.
  - **Deployment:** Nginx App 1
  - **NodePort Service:** Nginx App1
  - **Ingress Service:** Application Load Balancer
- Fargate 워크로드에는 `전용 EC2 워커 노드 - NodePort`가 없으므로 Ingress 매니페스트에 `target-type: ip` 관련 애노테이션을 추가합니다.

## 단계-02: 사전 준비
### eksctl CLI 사전 준비 안내
- eksctl은 지속적으로 새 기능이 추가되므로 최신 버전을 사용하는 것이 좋습니다.
- Mac에서는 아래 명령으로 최신 버전으로 업그레이드할 수 있습니다.
- 현재 AWS에서 Kubernetes의 빠른 발전 영역은 eksctl과 Fargate입니다.
- **eksctl 릴리스 URL:** https://github.com/weaveworks/eksctl/releases
```
# Check version
eksctl version

# Update eksctl on mac
brew upgrade eksctl && brew link --overwrite eksctl

# Check version
eksctl version
```

### ALB Ingress Controller 및 external-dns 사전 점검
- Fargate에 애플리케이션을 배포하기 전에 아래 두 컴포넌트가 NodeGroup에서 실행 중이어야 합니다.
  - ALB Ingress Controller
  - External DNS
- 애플리케이션은 배포 후 `fpdev.kubeoncloud.com`으로 등록된 DNS URL로 접근합니다.

```
# Get Current Worker Nodes in Kubernetes cluster
kubectl get nodes -o wide

# Verify Ingress Controller Pod running
kubectl get pods -n kube-system

# Verify external-dns Pod running
kubectl get pods
```

## 단계-03: eksdemo1 클러스터에 Fargate 프로파일 생성
### Fargate 프로파일 생성
```
# Get list of Fargate Profiles in a cluster
eksctl get fargateprofile --cluster eksdemo1

# Template
eksctl create fargateprofile --cluster <cluster_name> \
                             --name <fargate_profile_name> \
                             --namespace <kubernetes_namespace>


# Replace values
eksctl create fargateprofile --cluster eksdemo1 \
                             --name fp-demo \
                             --namespace fp-dev
```

### 출력 예시
```log
[ℹ]  Fargate pod execution role is missing, fixing cluster stack to add Fargate resources
[ℹ]  checking cluster stack for missing resources
[ℹ]  cluster stack is missing resources for Fargate
[ℹ]  adding missing resources to cluster stack
[ℹ]  re-building cluster stack "eksctl-eksdemo1-cluster"
[ℹ]  updating stack to add new resources [FargatePodExecutionRole] and outputs [FargatePodExecutionRoleARN]
[ℹ]  creating Fargate profile "fp-demo" on EKS cluster "eksdemo1"
[ℹ]  created Fargate profile "fp-demo" on EKS cluster "eksdemo1"
```
## 단계-04: NGINX App1 및 Ingress 매니페스트 검토
- Ingress Load Balancer와 함께 간단한 NGINX App1을 배포합니다.
- 다음 두 가지 이유로 Fargate 파드에 Worker Node NodePort를 사용할 수 없습니다.
  - Fargate 파드는 프라이빗 서브넷에 생성되므로 인터넷에서 접근할 수 없습니다.
  - Fargate 파드는 무작위 워커 노드에 생성되어 NodePort Service에서 사용할 노드 정보를 알 수 없습니다.
  - 다만 노드 그룹과 Fargate가 혼합된 환경에서 NodePort 서비스를 만들면 노드 그룹 EC2 워커 노드 포트로 서비스가 생성되어 동작하나, 해당 노드 그룹을 삭제하면 문제가 발생합니다.
  - Fargate 워크로드에는 Ingress 매니페스트에 `alb.ingress.kubernetes.io/target-type: ip`를 사용하는 것을 권장합니다.
### 네임스페이스 매니페스트 생성
- 이 네임스페이스 매니페스트는 Fargate 프로파일에서 생성한 네임스페이스 값 `fp-dev`와 일치해야 합니다.
```yml
apiVersion: v1
kind: Namespace
metadata: 
  name: fp-dev
```

### 나머지 매니페스트의 metadata 섹션에 namespace 태그 추가
```yml
  namespace: fp-dev 
```

### 모든 Deployment 매니페스트의 파드 템플릿에 리소스 설정 추가
- Fargate에서는 `cpu`, `memory`에 대한 `resources.requests`, `resources.limits`를 설정하는 것을 강력히 권장하며 사실상 필수에 가깝습니다.
- 이는 Fargate가 적절한 호스트를 스케줄링하는 데 도움을 줍니다.
- Fargate는 `Host:Pod`가 `1:1`인 구조이므로, 파드 템플릿(Deployment pod template spec)에 `resources` 섹션을 정의하는 것이 필수입니다.
- Deployment 파드 템플릿에 `resources`를 정의하지 않아도 NGINX 같은 저메모리 파드는 실행되지만, Spring Boot REST API 같은 고메모리 앱은 리소스 부족으로 계속 재시작할 수 있습니다.
```yml
          resources:
            requests:
              memory: "128Mi"
              cpu: "500m"
            limits:
              memory: "500Mi"
              cpu: "1000m"    
```

### Ingress 매니페스트 업데이트
- Fargate 서버리스에서 파드를 실행하므로 전용 EC2 워커 노드 개념이 없어 target-type을 IP로 변경해야 합니다.
- **중요:** `Node Groups & Fargate` 혼합 환경에서 동일한 Ingress를 사용할 경우, 이 애노테이션을 서비스 레벨에 적용할 수 있습니다.
```yml
    # For Fargate
    alb.ingress.kubernetes.io/target-type: ip    
```
- DNS 이름도 업데이트합니다.
```yml
    # External DNS - For creating a Record Set in Route53
    external-dns.alpha.kubernetes.io/hostname: fpdev.kubeoncloud.com   
```

## 단계-05: Fargate에 워크로드 배포
```
# 배포
kubectl apply -f kube-manifests/

# 네임스페이스 목록
kubectl get ns

# fp-dev 네임스페이스의 파드 목록
kubectl get pods -n fp-dev -o wide

# 워커 노드 목록
kubectl get nodes -o wide

# Ingress 목록
kubectl get ingress -n fp-dev
```

## 단계-06: 애플리케이션 접속 및 테스트
```
# 애플리케이션 접속
http://fpdev.kubeoncloud.com/app1/index.html
```


## 단계-07: Fargate 프로파일 삭제
```
# 클러스터의 Fargate 프로파일 목록 확인
eksctl get fargateprofile --cluster eksdemo1

# Fargate 프로파일 삭제
eksctl delete fargateprofile --cluster <cluster-name> --name <Fargate-Profile-Name> --wait
eksctl delete fargateprofile --cluster eksdemo1 --name fp-demo --wait
```


## 단계-08: NGINX App1이 관리형 노드 그룹에 스케줄되는지 확인
- Fargate 프로파일 삭제 후 Fargate에서 실행되던 앱은 노드 그룹이 존재하면 노드 그룹에 스케줄되고, 없으면 Pending 상태가 됩니다.
```
# fp-dev 네임스페이스의 파드 목록
kubectl get pods -n fp-dev -o wide
```

## 단계-09: 정리
```
# 삭제
kubectl delete -f kube-manifests/
```


## 참고 자료
- https://eksctl.io/usage/fargate-support/
- https://docs.aws.amazon.com/eks/latest/userguide/fargate.html
- https://kubernetes-sigs.github.io/aws-alb-ingress-controller/guide/ingress/annotation/#annotations
- https://kubernetes-sigs.github.io/aws-alb-ingress-controller/guide/ingress/annotation/#traffic-routing
