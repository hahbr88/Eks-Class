# AWS - 클래식 로드 밸런서 - CLB

## 단계-01: AWS 클래식 로드 밸런서 Kubernetes 매니페스트 생성 및 배포
- **04-ClassicLoadBalancer.yml**
```yml
apiVersion: v1
kind: Service
metadata:
  name: clb-usermgmt-restapp
  labels:
    app: usermgmt-restapp
spec:
  type: LoadBalancer  # 일반적인 k8s Service 매니페스트에서 type을 LoadBalancer로 설정
  selector:
    app: usermgmt-restapp     
  ports:
  - port: 80
    targetPort: 8095
```
---
```
Service.spec.type 에 들어갈 수 있는 값(종류)은 기본적으로 아래 4가지예요. (type을 안 쓰면 기본값은 ClusterIP)

1) ClusterIP (기본값)

클러스터 내부에만 가상 IP(Cluster IP)를 만들고 클러스터 내부 통신용으로만 노출

예: 내부 API, DB 앞단, 내부 마이크로서비스

2) NodePort

각 노드의 특정 포트(보통 30000~32767)를 열어서

NodeIP:NodePort 로 외부에서 접근 가능

클라우드 LB 없이도 테스트 가능하지만, 운영에서는 보통 LB와 같이 쓰거나 제한적으로 사용

3) LoadBalancer

클라우드 제공자(AWS 등)의 외부 로드밸런서를 붙여서 서비스 외부 노출

대부분 내부적으로는 NodePort/ClusterIP를 함께 구성한 뒤, 그 앞에 LB가 붙는 형태

예: type: LoadBalancer (지금 작성하신 케이스)

4) ExternalName

서비스에 프록시/로드밸런싱을 만들지 않고, 외부 DNS 이름(CNAME) 으로 매핑

예: spec.externalName: api.example.com

주로 “클러스터 밖의 서비스”를 내부 DNS처럼 쓰고 싶을 때
```
---


- **모든 매니페스트 배포**
```
# 모든 매니페스트 배포
kubectl apply -f kube-manifests/

# 서비스 목록 조회 (새로 생성된 CLB 서비스 확인)
kubectl get svc

# 파드 확인
kubectl get pods
```

## 단계-02: 배포 확인
- 새로운 CLB가 생성되었는지 확인
  - Services -> EC2 -> Load Balancing -> Load Balancers 로 이동
    - CLB가 생성되어 있어야 함
    - DNS 이름 복사 (예: a85ae6e4030aa4513bd200f08f1eb9cc-7f13b3acc1bcaaa2.elb.us-east-1.amazonaws.com)
  - Services -> EC2 -> Load Balancing -> Target Groups 로 이동
    - 헬스 상태를 확인하고 active 상태인지 확인
- **애플리케이션 접속**
```
# 애플리케이션 접속
http://<CLB-DNS-NAME>/usermgmt/health-status
```    

## 단계-03: 정리
```
# 생성된 모든 오브젝트 삭제
kubectl delete -f kube-manifests/

# 현재 Kubernetes 오브젝트 확인
kubectl get all
```
