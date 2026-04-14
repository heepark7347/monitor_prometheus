#!/usr/bin/env bash
# =============================================================================
# install-promtail-external.sh
# 외부 GPU 노드에 Promtail을 설치하고 systemd 서비스로 등록하는 스크립트
# 실행: sudo bash install-promtail-external.sh <HOSTNAME>
# 예시: sudo bash install-promtail-external.sh gpu-node-01
# =============================================================================
set -euo pipefail

HOSTNAME="${1:?'사용법: $0 <hostname> (예: gpu-node-01)'}"

PROMTAIL_VERSION="3.0.0"
LOKI_VIP="10.10.120.220"
LOKI_PORT="3100"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/promtail"

# =============================================================================
# [선택] 인터넷이 차단된 환경에서 패키지 다운로드 시 프록시 필요하면 설정
# 내부망에서 VIP로 직접 통신하는 Promtail 자체에는 HTTP_PROXY 불필요
# =============================================================================
# export HTTP_PROXY="http://<PROXY_IP>:<PORT>"
# export HTTPS_PROXY="http://<PROXY_IP>:<PORT>"
# export NO_PROXY="10.0.0.0/8,127.0.0.1,localhost"

echo "[1/5] Promtail ${PROMTAIL_VERSION} 다운로드..."
cd /tmp
curl -fSL \
  "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
  -o promtail-linux-amd64.zip
unzip -o promtail-linux-amd64.zip
install -m 755 promtail-linux-amd64 "${INSTALL_DIR}/promtail"
rm -f promtail-linux-amd64.zip promtail-linux-amd64
echo "  → ${INSTALL_DIR}/promtail 설치 완료"

echo "[2/5] 설정 디렉터리 생성..."
mkdir -p "${CONFIG_DIR}"

echo "[3/5] promtail 설정 파일 생성 (호스트: ${HOSTNAME})..."
# 리포지토리의 템플릿에서 __HOST__ 치환
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../configs/promtail/promtail-external.yaml"

if [[ -f "${TEMPLATE}" ]]; then
  sed "s/__HOST__/${HOSTNAME}/g" "${TEMPLATE}" > "${CONFIG_DIR}/config.yaml"
else
  # 템플릿 없을 경우 인라인 생성
  cat > "${CONFIG_DIR}/config.yaml" <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://${LOKI_VIP}:${LOKI_PORT}/loki/api/v1/push
    timeout: 10s
    backoff_config:
      min_period: 500ms
      max_period: 5m
      max_retries: 10

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${HOSTNAME}
          __path__: /var/log/*.log

  - job_name: journal
    journal:
      max_age: 12h
      labels:
        job: systemd-journal
        host: ${HOSTNAME}
    relabel_configs:
      - source_labels: [__journal__systemd_unit]
        target_label: unit
EOF
fi
echo "  → ${CONFIG_DIR}/config.yaml 생성 완료"

echo "[4/5] systemd 서비스 등록..."
cat > /etc/systemd/system/promtail.service <<EOF
[Unit]
Description=Promtail log shipper
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/promtail -config.file=${CONFIG_DIR}/config.yaml
Restart=on-failure
RestartSec=5s

# Promtail → Loki(VIP) 직접 통신이므로 HTTP_PROXY 불필요
# 인터넷 차단 환경에서 다른 목적지로의 프록시가 필요하면 아래 주석 해제
# Environment="HTTP_PROXY=http://<PROXY_IP>:<PORT>"
# Environment="HTTPS_PROXY=http://<PROXY_IP>:<PORT>"
# Environment="NO_PROXY=10.0.0.0/8,127.0.0.1,localhost,${LOKI_VIP}"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable promtail
systemctl start promtail
echo "  → promtail.service 등록 및 시작 완료"

echo "[5/5] 상태 확인..."
sleep 2
systemctl status promtail --no-pager || true

echo ""
echo "=== 설치 완료 ==="
echo "Loki 엔드포인트 : http://${LOKI_VIP}:${LOKI_PORT}/loki/api/v1/push"
echo "설정 파일       : ${CONFIG_DIR}/config.yaml"
echo "로그 확인       : journalctl -u promtail -f"
echo "연결 테스트     : curl -s http://${LOKI_VIP}:${LOKI_PORT}/ready"
