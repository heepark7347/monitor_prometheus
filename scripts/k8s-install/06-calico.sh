#!/usr/bin/env bash
# =============================================================================
# 06-calico.sh — Calico CNI 설치
# 실행 대상: k8s_master1 (10.10.120.232) — kubectl 접근 가능한 노드에서 실행
# 실행 방법: bash 06-calico.sh
# 의존성:
#   - 03-master1-init.sh 완료 후 즉시 실행 (CoreDNS Pending 상태 해소)
#   - kubeconfig 설정 완료 (~/.kube/config)
#
# Calico v3.28.0 — K8s v1.30 공식 지원 버전
# Pod CIDR: 192.168.0.0/16 (kubeadm-init.yaml 과 반드시 일치)
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [06-calico] 시작: Calico ${CALICO_VERSION} 설치 ==="

# ── 1. Tigera Operator 설치 ───────────────────────────────────────────────────
# Operator 방식이 Calico 권장 설치 방법 (v3.15+)
echo "--- [1/3] Tigera Operator 설치"
kubectl create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# Operator 기동 대기
echo "    Tigera Operator 준비 대기 중..."
kubectl rollout status deployment/tigera-operator \
  -n tigera-operator \
  --timeout=120s

# ── 2. Calico Installation CR 적용 ───────────────────────────────────────────
echo "--- [2/3] Calico Installation 리소스 적용"
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Pod CIDR — kubeadm-init.yaml 의 podSubnet 과 동일해야 함
  calicoNetwork:
    ipPools:
      - blockSize: 26
        cidr: "${POD_CIDR}"
        encapsulation: VXLANCrossSubnet  # 온프레미스 단일 L2 환경에 최적
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

# ── 3. Calico 기동 대기 ───────────────────────────────────────────────────────
echo "--- [3/3] Calico 컴포넌트 Ready 대기 (최대 5분)"
echo "    calico-system 네임스페이스의 Pod 가 모두 Running 될 때까지 대기..."

# calico-node DaemonSet 이 모든 노드에 배포될 때까지 대기
kubectl rollout status daemonset/calico-node \
  -n calico-system \
  --timeout=300s

# calico-kube-controllers 대기
kubectl rollout status deployment/calico-kube-controllers \
  -n calico-system \
  --timeout=120s

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -n calico-system

echo "=== [06-calico] 완료 ==="
echo ""
echo "다음 단계:"
echo "  1. master2/3 조인: 04-master-join.sh"
echo "  2. proxy1/2 조인: 05-worker-join.sh"
echo "  3. 레이블/테인트: 07-label-taint.sh (모든 노드 조인 후)"
