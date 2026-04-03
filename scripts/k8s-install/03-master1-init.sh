#!/usr/bin/env bash
# =============================================================================
# 03-master1-init.sh — 첫 번째 컨트롤 플레인 초기화
# 실행 대상: k8s_master1 (10.10.120.232) 단독 실행
# 실행 방법: sudo bash 03-master1-init.sh
# 의존성:
#   - 전 노드: 01-common.sh 완료
#   - proxy1/proxy2: 02-haproxy-keepalived.sh 완료 (VIP 10.10.120.229 활성 확인)
#
# 완료 후 출력되는 join 명령어를 안전한 곳에 보관 → 04/05 스크립트에서 사용
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
JOIN_CMD_DIR="${REPO_ROOT}/scripts/k8s-install/join-tokens"

echo "=== [03-master1-init] 시작: $(hostname) ==="

# ── 사전 확인 ─────────────────────────────────────────────────────────────────
echo "--- [pre-check] VIP 접근 확인"
# HAProxy/keepalived 가 VIP 를 정상적으로 서비스해야 초기화 가능
nc -zv "${CONTROL_PLANE_VIP}" "${CONTROL_PLANE_PORT}" 2>&1 || {
  echo "ERROR: VIP ${CONTROL_PLANE_VIP}:${CONTROL_PLANE_PORT} 에 연결 불가"
  echo "       proxy1/proxy2 에서 02-haproxy-keepalived.sh 가 완료됐는지 확인하세요"
  exit 1
}

# ── 1. kubeadm 사전 검사 ──────────────────────────────────────────────────────
echo "--- [1/5] kubeadm preflight 검사"
kubeadm config images pull --config "${REPO_ROOT}/configs/kubeadm/kubeadm-init.yaml"

# ── 2. 클러스터 초기화 ────────────────────────────────────────────────────────
echo "--- [2/5] kubeadm init 실행"
kubeadm init \
  --config "${REPO_ROOT}/configs/kubeadm/kubeadm-init.yaml" \
  --upload-certs \
  2>&1 | tee /tmp/kubeadm-init.log

# ── 3. kubeconfig 설정 ────────────────────────────────────────────────────────
echo "--- [3/5] kubeconfig 설정"
# root 사용자
export KUBECONFIG=/etc/kubernetes/admin.conf

# 일반 사용자 (스크립트 실행 계정)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
mkdir -p "${REAL_HOME}/.kube"
cp -i /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${REAL_HOME}/.kube/config"
echo "    kubeconfig → ${REAL_HOME}/.kube/config"

# ── 4. Join 명령어 추출 및 저장 ───────────────────────────────────────────────
# join 토큰은 24시간 후 만료된다. 보안상 안전한 위치에 보관할 것.
echo "--- [4/5] Join 명령어 추출"
mkdir -p "${JOIN_CMD_DIR}"

# 컨트롤 플레인(master2/3) 용 join 명령
grep -A 4 "kubeadm join" /tmp/kubeadm-init.log \
  | grep -A 3 "control-plane" \
  > "${JOIN_CMD_DIR}/control-plane-join.txt" 2>/dev/null || true

# 전체 join 블록 저장 (worker 조인 포함)
cat /tmp/kubeadm-init.log > "${JOIN_CMD_DIR}/kubeadm-init-full.log"

# certificate-key 재발급 (위 명령이 24h 후 만료되므로 기록 용도)
echo "" >> "${JOIN_CMD_DIR}/control-plane-join.txt"
echo "# certificate-key 재발급 명령:" >> "${JOIN_CMD_DIR}/control-plane-join.txt"
echo "# sudo kubeadm init phase upload-certs --upload-certs" >> "${JOIN_CMD_DIR}/control-plane-join.txt"

echo "    Join 정보 저장: ${JOIN_CMD_DIR}/"
echo "    !! join-tokens/ 디렉터리는 .gitignore 에 등록됩니다 (토큰 노출 방지)"

# .gitignore 에 토큰 디렉터리 추가
if ! grep -q "join-tokens" "${REPO_ROOT}/.gitignore" 2>/dev/null; then
  echo "scripts/k8s-install/join-tokens/" >> "${REPO_ROOT}/.gitignore"
fi

# ── 5. 초기화 상태 확인 ───────────────────────────────────────────────────────
echo "--- [5/5] 클러스터 초기 상태 확인"
kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf
kubectl get pods -n kube-system --kubeconfig /etc/kubernetes/admin.conf

echo ""
echo "=== [03-master1-init] 완료 ==="
echo ""
echo "다음 단계:"
echo "  1. Calico 설치: 06-calico.sh (CNI 없으면 CoreDNS 가 Pending 상태)"
echo "  2. master2/master3: 04-master-join.sh 실행"
echo "     join 명령: cat ${JOIN_CMD_DIR}/kubeadm-init-full.log | grep -A 10 'control-plane'"
echo "  3. proxy1/proxy2: 05-worker-join.sh 실행"
