#!/usr/bin/env bash
# =============================================================================
# 08-post-install.sh — 클러스터 설치 후 공통 설정
# 실행 대상: k8s_master1 (kubectl 접근 가능한 노드)
# 실행 방법: bash 08-post-install.sh
# 의존성: 07-label-taint.sh 완료 후 실행
#
# 수행 항목:
#   1. monitoring namespace 생성
#   2. helm v3 설치 확인
#   3. 클러스터 최종 상태 출력
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [08-post-install] 시작 ==="

# ── 1. monitoring namespace 생성 ──────────────────────────────────────────────
echo "--- [1/3] monitoring namespace 생성"
kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl get namespace "${MONITORING_NS}"

# ── 2. helm v3 설치 확인 / 설치 ──────────────────────────────────────────────
echo "--- [2/3] helm v3 확인"
if ! command -v helm &>/dev/null; then
  echo "    helm 미설치 → 설치 진행"
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | bash
else
  echo "    helm $(helm version --short) 이미 설치됨"
fi

# ── 3. 최종 클러스터 상태 확인 ────────────────────────────────────────────────
echo "--- [3/3] 최종 클러스터 상태"
echo ""
echo "[ 노드 목록 ]"
kubectl get nodes -o wide

echo ""
echo "[ kube-system Pod ]"
kubectl get pods -n kube-system -o wide

echo ""
echo "[ calico-system Pod ]"
kubectl get pods -n calico-system -o wide

echo ""
echo "=== [08-post-install] 완료 ==="
echo ""
echo "클러스터 설치가 완료되었습니다."
echo "다음 단계: helm/values/ 의 values 파일을 참고하여 모니터링 스택 배포"
