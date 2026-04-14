#!/usr/bin/env bash
# =============================================================================
# 05-worker-join.sh — 워커 노드 조인 (proxy1, proxy2)
# 실행 대상: proxy1 (10.10.120.230), proxy2 (10.10.120.231)
# 실행 방법: sudo bash 05-worker-join.sh
# 의존성:
#   - 01-common.sh 완료
#   - 02-haproxy-keepalived.sh 완료
#   - 03-master1-init.sh 완료
#
# proxy1/proxy2 는 워커 전용 (--control-plane 플래그 없음)
# HAProxy/keepalived 는 K8s 외부 프로세스이므로 manifest 대상 아님
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [05-worker-join] 시작: $(hostname) ==="

# ── 1. join 명령어 확인 ───────────────────────────────────────────────────────
echo "--- [1/2] join 명령어 확인"
echo ""
echo "k8s-master1 에서 아래 명령으로 워커 join 명령을 확인하세요:"
echo "  kubeadm token create --print-join-command"
echo ""
echo "토큰이 만료된 경우 위 명령으로 재발급 가능합니다."
echo ""

# join 명령을 환경변수로 주입한다.
# 방법:
#   export WORKER_JOIN_CMD="kubeadm join 10.10.120.220:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
#   sudo -E bash 05-worker-join.sh
WORKER_JOIN_CMD="${WORKER_JOIN_CMD:-}"

if [[ -z "${WORKER_JOIN_CMD}" ]]; then
  echo "ERROR: WORKER_JOIN_CMD 환경변수가 설정되지 않았습니다."
  echo ""
  echo "사용법:"
  echo "  export WORKER_JOIN_CMD=\"kubeadm join 10.10.120.220:6443 \\"
  echo "    --token <token> \\"
  echo "    --discovery-token-ca-cert-hash sha256:<hash>\""
  echo "  sudo -E bash 05-worker-join.sh"
  exit 1
fi

# ── 2. 워커 노드 조인 ─────────────────────────────────────────────────────────
echo "--- [2/2] 워커 노드 조인"
eval "${WORKER_JOIN_CMD}"

echo "=== [05-worker-join] 완료: $(hostname) ==="
echo ""
echo "k8s-master1 에서 노드 상태 확인:"
echo "  kubectl get nodes -o wide"
echo ""
echo "다음 단계: k8s-master1 에서 07-label-taint.sh 실행 (모든 노드 조인 후)"
