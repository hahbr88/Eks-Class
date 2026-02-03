---
title: AWS Load Balancer Controller - NLB 기본
description: AWS Load Balancer Controller로 AWS Network Load Balancer를 사용하는 방법 학습
---

## 단계-01: 소개
- 다음 내용을 이해합니다.
  - **AWS Cloud Provider Load Balancer Controller(레거시):** AWS CLB와 NLB 생성
  - **AWS Load Balancer Controller(최신):** AWS ALB와 NLB 생성
- AWS NLB를 생성할 수 있는 Kubernetes Service(Type=LoadBalancer)를 최신 `AWS Load Balancer Controller`와 연동하는 방식을 이해합니다.
- 다양한 NLB 애노테이션을 이해합니다.


## 단계-02: 01-Nginx-App3-Deployment.yml 검토
- **파일 이름:** `kube-manifests/01-Nginx-App3-Deployment.yml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app3-nginx-deployment
  labels:
    app: app3-nginx 
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app3-nginx
  template:
    metadata:
      labels:
        app: app3-nginx
    spec:
      containers:
        - name: app2-nginx
          image: stacksimplify/kubenginx:1.0.0
          ports:
            - containerPort: 80

```

## 단계-03: 02-LBC-NLB-LoadBalancer-Service.yml 검토
- **파일 이름:** `kube-manifests\\02-LBC-NLB-LoadBalancer-Service.yml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: basics-lbc-network-lb
  annotations:
    # Traffic Routing
    service.beta.kubernetes.io/aws-load-balancer-name: basics-lbc-network-lb
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    #service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-xxxx, mySubnet ## Subnets are auto-discovered if this annotation is not specified, see Subnet Discovery for further details.
    
    # Health Check Settings
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: http
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: traffic-port
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: /index.html
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "3"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "3"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "10" # The controller currently ignores the timeout configuration due to the limitations on the AWS NLB. The default timeout for TCP is 10s and HTTP is 6s.

    # Access Control
    service.beta.kubernetes.io/load-balancer-source-ranges: 0.0.0.0/0 
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

    # AWS Resource Tags
    service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: Environment=dev,Team=test
spec:
  type: LoadBalancer
  selector:
    app: app3-nginx
  ports:
    - port: 80
      targetPort: 80
```

## 단계-04: kube-manifests 전체 배포
```t
# Deploy kube-manifests
kubectl apply -f kube-manifests/

# 파드 확인
kubectl get pods

# 서비스 확인
kubectl get svc
관찰 사항:
1. 네트워크 LB DNS 이름 확인

# AWS Load Balancer Controller 파드 로그 확인
kubectl -n kube-system get pods
kubectl -n kube-system logs -f <aws-load-balancer-controller-POD-NAME>

# AWS 관리 콘솔에서 확인
Services -> EC2 -> Load Balancing -> Load Balancers로 이동
1. Description 탭에서 "kubectl get svc" External IP와 일치하는 DNS Name 확인
2. Listeners 탭 확인

Services -> EC2 -> Load Balancing -> Target Groups로 이동
1. 등록된 대상 확인
2. Health Check 경로 확인

# 애플리케이션 접속
http://<NLB-DNS-NAME>
```

## 단계-05: 정리
```t
# kube-manifests 삭제 또는 언배포
kubectl delete -f kube-manifests/

# NLB 삭제 여부 확인
AWS 관리 콘솔에서,
Services -> EC2 -> Load Balancing -> Load Balancers로 이동
```

## 참고 자료
- [Network Load Balancer](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)
- [NLB Service](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/nlb/)
- [NLB Service Annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/)
