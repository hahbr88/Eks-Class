---
title: AWS Load Balancer Controller - NLB Elastic IP
description: AWS Load Balancer Controller로 AWS Network Load Balancer와 Elastic IP를 사용하는 방법 학습
---

## 단계-01: 소개
- Elastic IP 생성
- EIP 할당 ID로 Elastic IP 애노테이션을 NLB Service K8s 매니페스트에 반영

## 단계-02: Elastic IP 2개 생성 및 EIP 할당 ID 확인
- 이 구성은 선택 사항이며 NLB에 정적 IP 주소를 할당할 때 사용합니다.
- 로드 밸런서 서브넷 애노테이션과 동일한 개수의 EIP 할당을 지정해야 합니다.
- NLB는 internet-facing이어야 합니다.
```t
# Elastic IP Allocation IDs
eipalloc-07daf60991cfd21f0 
eipalloc-0a8e8f70a6c735d16
```

## 단계-03: Elastic IP 애노테이션 검토
- **파일 이름:** `kube-manifests\\02-LBC-NLB-LoadBalancer-Service.yml`
```yaml
    # Elastic IPs
    service.beta.kubernetes.io/aws-load-balancer-eip-allocations: eipalloc-07daf60991cfd21f0, eipalloc-0a8e8f70a6c735d16
```

## 단계-04: kube-manifests 전체 배포
```t
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

# nslookup 테스트 수행
nslookup nlbeip201.stacksimplify.com
관찰 사항:
1. IP 주소가 단계-02에서 생성한 Elastic IP와 일치하는지 확인

# 애플리케이션 접속
# HTTP URL 테스트
http://nlbeip201.stacksimplify.com

# HTTPS URL 테스트
https://nlbeip201.stacksimplify.com
```

## 단계-05: 정리
```t
# kube-manifests 삭제 또는 언배포
kubectl delete -f kube-manifests/

## 생성한 Elastic IP 삭제
AWS 관리 콘솔에서,
Services -> EC2 -> Network & Security -> Elastic IPs로 이동
생성한 EIP 2개 삭제

# NLB 삭제 여부 확인
AWS 관리 콘솔에서,
Services -> EC2 -> Load Balancing -> Load Balancers로 이동
```

## 참고 자료
- [Network Load Balancer](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)
- [NLB Service](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/nlb/)
- [NLB Service Annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/guide/service/annotations/)
