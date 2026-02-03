---
title: AWS Load Balancer Controller - NLB External DNS
description: AWS Load Balancer Controller로 AWS Network Load Balancer와 External DNS를 사용하는 방법 학습
---

## 단계-01: 소개
- NLB Kubernetes Service 매니페스트에 External DNS 애노테이션을 적용합니다.


## 단계-02: External DNS 애노테이션 검토
- **파일 이름:** `kube-manifests\\02-LBC-NLB-LoadBalancer-Service.yml`
```yaml
    # External DNS - For creating a Record Set in Route53
    external-dns.alpha.kubernetes.io/hostname: nlbdns101.stacksimplify.com
```

## 단계-03: kube-manifests 전체 배포
```t
# External DNS 파드 존재 및 실행 여부 확인
kubectl get pods
관찰 사항:
external-dns 파드가 실행 중이어야 합니다.

# kube-manifests 배포
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
관찰 사항: 포트 80과 443의 두 리스너가 보여야 합니다.

Services -> EC2 -> Load Balancing -> Target Groups로 이동
1. 등록된 대상 확인
2. Health Check 경로 확인
관찰 사항: 타깃 그룹 2개가 보여야 하며, 리스너 1개당 타깃 그룹 1개입니다.

# External DNS 로그 확인
kubectl logs -f $(kubectl get po | egrep -o 'external-dns[A-Za-z0-9-]+')

# nslookup 테스트 수행
nslookup nlbdns101.stacksimplify.com

# 애플리케이션 접속
# HTTP URL 테스트
http://nlbdns101.stacksimplify.com

# HTTPS URL 테스트
https://nlbdns101.stacksimplify.com
```

## 단계-04: 정리
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
