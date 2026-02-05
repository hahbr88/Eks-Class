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
eksctl create fargateprofile --cluster eksdemo3 \
                             --name fp-demo \
                             --namespace fp-dev
```
---
# EKS Fargate Profile 리소스 개념 & eksctl Kubernetes 버전(1.32 → 1.35) 설정/업그레이드 가이드

> 목적:  
> 1) **EKS에서 Fargate는 “프로파일(Profile)” 개념인데, AWS에서 어떤 리소스로 잡히는지**  
> 2) **eksctl로 쿠버네티스 버전을 최신(예: 1.35)로 생성/업그레이드하는 방법**

---

## 1. EKS에서 Fargate Profile은 “어떤 리소스”인가?

### 1.1 핵심 개념
- **Fargate Profile**은 EKS 클러스터에서 **“스케줄링 규칙(Selector)”** 역할을 합니다.
- 특정 **Namespace(+선택적으로 Label)** 에 매칭되는 Pod를 **Fargate 런타임**에서 실행하도록 선언합니다.

### 1.2 AWS에서 어떤 리소스로 잡히나?
- **Fargate Profile 자체는 EKS 관리형 리소스**입니다.
- 콘솔에서는 보통 다음 위치에서 확인합니다.
  - **EKS Console → Cluster → Compute → Fargate profiles**
- CloudFormation으로 생성할 경우 리소스 타입은:
  - `AWS::EKS::FargateProfile`

### 1.3 Fargate Profile과 함께 따라오는 것들(실무에서 중요한 연관 리소스)
Fargate Profile 하나를 만든다고 “컴퓨트가 바로 보이는 EC2 인스턴스”가 생기진 않습니다. 대신 다음 요소들이 함께 연결됩니다.

1) **Pod execution IAM Role**
- Fargate가 Pod를 실행할 때 필요한 **Pod execution role**을 지정합니다.
- 이미지 Pull(ECR), 로그 전송(CloudWatch) 등 실행에 필요한 권한이 여기에 포함됩니다.

2) **네트워크(ENI / Subnet IP 소모)**
- Fargate는 Pod 단위로 격리된 실행 환경을 제공하는 구조라서, 네트워킹 관점에서 **ENI/서브넷 IP 소비**가 핵심 이슈가 됩니다.
- **서브넷 IP 부족**이 생기면 Fargate Pod 스케줄링이 막히거나 지연될 수 있습니다.

3) Kubernetes에서 Fargate로 뜬 Pod 확인 포인트
- `eks.amazonaws.com/compute-type=fargate` 같은 라벨/특성으로 구분되는 경우가 많습니다.
- 스케줄링이 Fargate로 되었는지 파드 이벤트/노드 매핑 정보로 확인할 수 있습니다.

---

## 2. eksctl에서 Kubernetes 버전을 최신(예: 1.35)로 생성/업그레이드

### 2.1 “최신 버전” 확인 (리전별 지원 버전이 제일 정확)
EKS는 **리전(ap-northeast-2 등)에 따라 지원 버전이 다를 수 있으므로**, 아래 명령으로 확인하는 게 가장 정확합니다.

```bash
aws eks describe-cluster-versions \
  --region ap-northeast-2 \
  --query 'clusters[].clusterVersions[]' \
  --output text
```

- 출력에 `1.35`가 보이면 해당 리전에서 생성/업그레이드가 가능한 상태입니다.

---

### 2.2 새 클러스터를 1.35로 “생성”
eksctl 생성 시 버전을 지정합니다.

```bash
eksctl create cluster \
  --name <클러스터명> \
  --region ap-northeast-2 \
  --version 1.35
```

> 참고: config yaml로 생성하는 경우에도 `metadata.version`에 버전을 지정하는 방식으로 동일하게 적용됩니다.

---

### 2.3 기존 1.32 클러스터를 1.35로 “업그레이드” (중요: 마이너 1단계씩)
EKS 업그레이드는 보통 **한 번에 마이너 버전 1단계씩** 진행하는 것이 원칙입니다.

즉:
- `1.32 → 1.33 → 1.34 → 1.35`

예시:

```bash
eksctl upgrade cluster --name <클러스터명> --region ap-northeast-2 --version 1.33
eksctl upgrade cluster --name <클러스터명> --region ap-northeast-2 --version 1.34
eksctl upgrade cluster --name <클러스터명> --region ap-northeast-2 --version 1.35
```

---

### 2.4 실무 팁: “왜 1.32로 생성됐지?”
가장 흔한 원인:
- **eksctl 버전이 오래된 경우**
  - 기본값/검증 로직 때문에 최신 버전(예: 1.35)을 못 쓰거나, 기본이 낮은 버전으로 잡히는 일이 있습니다.

확인:

```bash
eksctl version
```

업데이트 후 다시 생성/업그레이드를 시도하면 해결되는 케이스가 많습니다.

---

## 3. 빠른 점검 체크리스트 (선택)

### 3.1 현재 클러스터 버전 확인
```bash
aws eks describe-cluster \
  --name <클러스터명> \
  --region ap-northeast-2 \
  --query 'cluster.version' \
  --output text
```

### 3.2 Fargate profile 목록 확인
```bash
aws eks list-fargate-profiles \
  --cluster-name <클러스터명> \
  --region ap-northeast-2
```

### 3.3 특정 Fargate profile 상세 확인
```bash
aws eks describe-fargate-profile \
  --cluster-name <클러스터명> \
  --fargate-profile-name <프로파일명> \
  --region ap-northeast-2
```

---

## 4. 다음 단계(원하면 만들어드릴 수 있는 것)
- 현재 클러스터(들)의 **Control Plane 버전 / Fargate profile 존재 여부 / Selector(namespace,label) 매칭**을 한 번에 점검하는 **진단용 bash 스크립트**
- Fargate/NodeGroup 혼합 환경에서 **네임스페이스별 스케줄링 정책 설계 예시**
---
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
---
# AWS Lambda vs AWS Fargate 차이점 정리

둘 다 “서버를 직접 관리하지 않고 실행”한다는 점은 같지만, **목적/실행 모델/제약**이 달라서 쓰임새가 확연히 다릅니다.

---

## 1) 한 줄 요약

- **AWS Lambda**: 이벤트가 오면 *함수(코드 조각)* 를 짧게 실행하는 **서버리스 함수(Function-as-a-Service)**
- **AWS Fargate**: *컨테이너(서비스/배치)* 를 실행하는 **서버리스 컨테이너 런타임**

---

## 2) 핵심 차이점 비교

### 2.1 실행 단위
- **Lambda**: 함수(핸들러) 단위 실행 (코드 + 런타임 중심)
- **Fargate**: 컨테이너 이미지(Docker) 단위 실행 (OS/라이브러리/프로세스 포함)

### 2.2 실행 방식(라이프사이클)
- **Lambda**: 요청(이벤트)마다 실행되고 종료되는 모델(짧게 여러 번)
- **Fargate**:  
  - **항상 켜진 서비스** (ECS Service / EKS Deployment)  
  - **한 번 실행하는 배치** (ECS Task / K8s Job)  
  형태로 운용 가능

### 2.3 네트워킹 관점
- **Lambda**
  - VPC 없이도 실행 가능(기본은 AWS 내부 네트워크)
  - VPC에 붙이면 ENI 등 고려 필요
- **Fargate**
  - 보통 VPC 안에서 컨테이너가 뜸(Subnet/SG/IP 설계 중요)
  - EKS Fargate는 “특정 Namespace/Label로 매칭되는 Pod를 Fargate로 실행”하는 모델

### 2.4 성능/지연(콜드스타트)
- **Lambda**: 콜드스타트 이슈 가능(특히 VPC 연결/패키지 크기/런타임에 따라 체감)
- **Fargate**: 컨테이너 시작(스케줄링/이미지 pull) 시간이 들 수 있으나, 서비스로 유지하면 지연이 안정적

### 2.5 적합한 워크로드(무엇에 쓰는 게 좋은가)
- **Lambda가 유리한 경우**
  - API Gateway + 간단한 백엔드
  - S3 업로드 이벤트 처리(썸네일/ETL 트리거)
  - 스케줄 기반 작업(크론), 알림/웹훅 처리
  - 트래픽이 들쭉날쭉하고 “짧은 작업” 위주
- **Fargate가 유리한 경우**
  - 컨테이너 기반 웹서비스/마이크로서비스(장시간 실행)
  - WebSocket, 장기 연결, 백그라운드 워커
  - 특정 바이너리/라이브러리/커스텀 런타임이 필요한 경우
  - EKS/ECS의 표준 운영(Deployment/Service/Autoscaling)을 그대로 쓰고 싶을 때

### 2.6 운영 모델(관리 포인트)
- **Lambda**: 서버/컨테이너 운영 부담이 최소(대신 함수 단위 설계/권한/관측 설계가 중요)
- **Fargate**: 컨테이너 운영(이미지 빌드/태그/배포/스케일링)은 필요하지만 **노드(EC2) 운영은 없음**

---

## 3) 빠른 선택 가이드(실무용)

- “**짧게 끝나는 이벤트 처리**” → **Lambda**
- “**컨테이너로 서비스/워커를 계속 실행**” → **Fargate**
- 이미 **EKS 표준으로 운영 중**이고 “노드 운영만 제거” → **EKS on Fargate**
- 호출량이 들쭉날쭉하고 코드가 단순 → **Lambda가 비용/운영 면에서 깔끔한 경우가 많음**
- OS 패키지/바이너리/복잡한 런타임 필요 → **Fargate가 훨씬 편함**

---

## 4) 참고: EKS 관점에서의 Fargate
- **Fargate Profile**은 “스케줄링 규칙”이며, 특정 Namespace/Label로 매칭되는 Pod가 Fargate에서 실행됩니다.
- “노드를 직접 운영(패치/스케일/용량)하지 않고도” EKS 워크로드를 실행할 수 있다는 점이 장점입니다.

---

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
