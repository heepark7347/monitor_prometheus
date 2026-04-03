#!/usr/bin/env bash
# =============================================================================
# 02-haproxy-keepalived.sh — HAProxy + keepalived 설치 및 설정
# 실행 대상: proxy1 (10.10.120.230), proxy2 (10.10.120.231)
# 실행 방법: sudo bash 02-haproxy-keepalived.sh [proxy1|proxy2]
# 의존성: 01-common.sh 완료 후 실행
#
# 역할:
#   - HAProxy: k8s API 서버(6443)를 master1/2/3 로 로드밸런싱
#   - keepalived: VIP(10.10.120.229) VRRP 관리, HAProxy 장애 시 자동 페일오버
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

# 인자로 노드 역할을 받는다 (proxy1 또는 proxy2)
NODE_ROLE="${1:-}"
if [[ "$NODE_ROLE" != "proxy1" && "$NODE_ROLE" != "proxy2" ]]; then
  echo "사용법: sudo bash $0 [proxy1|proxy2]"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== [02-haproxy-keepalived] 시작: $(hostname) (${NODE_ROLE}) ==="

# ── 1. 패키지 설치 ────────────────────────────────────────────────────────────
echo "--- [1/4] HAProxy / keepalived 설치"
apt-get update -y
apt-get install -y haproxy keepalived

# ── 2. HAProxy 설정 배포 ──────────────────────────────────────────────────────
echo "--- [2/4] HAProxy 설정 파일 배포"
cp -v "${REPO_ROOT}/configs/haproxy/haproxy.cfg" /etc/haproxy/haproxy.cfg
# 설정 파일 문법 검사
haproxy -c -f /etc/haproxy/haproxy.cfg

systemctl enable haproxy
systemctl restart haproxy
echo "    HAProxy 상태: $(systemctl is-active haproxy)"

# ── 3. keepalived 설정 배포 ───────────────────────────────────────────────────
echo "--- [3/4] keepalived 설정 파일 배포 (${NODE_ROLE})"
cp -v "${REPO_ROOT}/configs/keepalived/keepalived-${NODE_ROLE}.conf" \
      /etc/keepalived/keepalived.conf

# keepalived 은 비특권 컨테이너와 무관하지만 net_bind_service 필요
systemctl enable keepalived
systemctl restart keepalived
echo "    keepalived 상태: $(systemctl is-active keepalived)"

# ── 4. VIP 확인 ──────────────────────────────────────────────────────────────
echo "--- [4/4] VIP 확인 (proxy1에만 VIP가 올라와야 함)"
sleep 3
ip addr show "${VIP_INTERFACE}" | grep -E "inet " || true

echo "=== [02-haproxy-keepalived] 완료: $(hostname) ==="
echo "다음 단계: k8s-master1 에서 03-master1-init.sh 실행"
