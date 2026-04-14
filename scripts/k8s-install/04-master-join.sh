#!/usr/bin/env bash
# =============================================================================
# 04-master-join.sh — 추가 컨트롤 플레인 노드 조인 (master2, master3)
# 실행 대상: k8s_master2 (10.10.120.233), k8s_master3 (10.10.120.234)
# 실행 방법: sudo bash 04-master-join.sh
# 의존성:
#   - 01-common.sh 완료
#   - 03-master1-init.sh 완료 (join 토큰 확인 필요)
#
# 주의:
#   - 03-master1-init.sh 출력의 "kubeadm join ... --control-plane" 명령 사용
#   - 토큰은 24시간 후 만료 → 재발급: kubeadm token create --print-join-command
#   - certificate-key 는 2시간 후 만료 → 재발급: kubeadm init phase upload-certs --upload-certs
#
# 이 스크립트는 직접 join 명령을 실행하지 않는다.
# join 명령을 CONTROL_PLANE_JOIN_CMD 변수에 할당하여 실행한다.
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [04-master-join] 시작: $(hostname) ==="

# ── 1. join 명령어 확인 ───────────────────────────────────────────────────────
echo "--- [1/3] join 명령어 확인"
echo ""
echo "아래 내용을 k8s-master1 에서 확인하세요:"
echo "  cat scripts/k8s-install/join-tokens/kubeadm-init-full.log | grep -A 10 'control-plane'"
echo ""
echo "형식 예시:"
echo "  kubeadm join 10.10.120.220:6443 \\"
echo "    --token <token> \\"
echo "    --discovery-token-ca-cert-hash sha256:<hash> \\"
echo "    --control-plane \\"
echo "    --certificate-key <cert-key>"
echo ""

# ── 2. join 명령 실행 ─────────────────────────────────────────────────────────
# join 명령을 환경변수로 주입하거나 직접 입력한다.
# 방법 A: 환경변수 사용
#   export CONTROL_PLANE_JOIN_CMD="kubeadm join 10.10.120.220:6443 --token ... --control-plane --certificate-key ..."
#   sudo bash 04-master-join.sh
#
# 방법 B: 스크립트 안에서 직접 입력 (아래 변수를 채워서 사용)
CONTROL_PLANE_JOIN_CMD="${CONTROL_PLANE_JOIN_CMD:-}"

if [[ -z "${CONTROL_PLANE_JOIN_CMD}" ]]; then
  echo "ERROR: CONTROL_PLANE_JOIN_CMD 환경변수가 설정되지 않았습니다."
  echo ""
  echo "사용법:"
  echo "  export CONTROL_PLANE_JOIN_CMD=\"kubeadm join 10.10.120.220:6443 \\"
  echo "    --token <token> \\"
  echo "    --discovery-token-ca-cert-hash sha256:<hash> \\"
  echo "    --control-plane \\"
  echo "    --certificate-key <cert-key>\""
  echo "  sudo -E bash 04-master-join.sh"
  exit 1
fi

echo "--- [2/3] 컨트롤 플레인 노드 조인"
eval "${CONTROL_PLANE_JOIN_CMD}"

# ── 3. kubeconfig 설정 ────────────────────────────────────────────────────────
echo "--- [3/3] kubeconfig 설정"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
mkdir -p "${REAL_HOME}/.kube"
cp -i /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${REAL_HOME}/.kube/config"

echo "=== [04-master-join] 완료: $(hostname) ==="
echo ""
echo "k8s-master1 에서 노드 상태 확인:"
echo "  kubectl get nodes -o wide"
