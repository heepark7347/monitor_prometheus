#!/usr/bin/env bash
# =============================================================================
# scripts/enable-dcgm-fan-speed.sh
#
# GPU 서버에서 DCGM exporter에 DCGM_FI_DEV_FAN_SPEED 수집을 추가합니다.
# 실행 위치: GPU 서버 (183.111.14.6) 에서 직접 실행
#
# 주의: A100 / H100 / 대부분의 데이터센터 GPU는 패시브 쿨링으로
#       DCGM_FI_DEV_FAN_SPEED가 항상 N/A 또는 미지원일 수 있습니다.
# =============================================================================
set -euo pipefail

COUNTER_FILE="${DCGM_COUNTER_FILE:-/etc/dcgm-exporter/default-counters.csv}"
FAN_ENTRY="DCGM_FI_DEV_FAN_SPEED, gauge, Fan speed (%), 0-100"

echo "[1/4] DCGM exporter 카운터 파일 위치 확인..."

# Docker로 실행 중인 경우
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q dcgm; then
  CONTAINER=$(docker ps --format '{{.Names}}' | grep dcgm | head -1)
  echo "  → Docker 컨테이너 발견: ${CONTAINER}"

  echo "[2/4] 현재 카운터 파일을 호스트로 복사..."
  docker cp "${CONTAINER}:${COUNTER_FILE}" /tmp/dcgm-counters-backup.csv
  cp /tmp/dcgm-counters-backup.csv /tmp/dcgm-counters-new.csv

  echo "[3/4] FAN_SPEED 항목 추가..."
  if grep -q "DCGM_FI_DEV_FAN_SPEED" /tmp/dcgm-counters-new.csv; then
    echo "  → 이미 존재합니다. 스킵."
  else
    # 온도 항목 다음에 삽입
    sed -i "/DCGM_FI_DEV_GPU_TEMP/a ${FAN_ENTRY}" /tmp/dcgm-counters-new.csv
    echo "  → 추가 완료."
  fi

  echo "[4/4] 수정된 파일을 컨테이너에 복사 후 재시작..."
  docker cp /tmp/dcgm-counters-new.csv "${CONTAINER}:${COUNTER_FILE}"
  docker restart "${CONTAINER}"
  echo "  → 컨테이너 재시작 완료."

# systemd 서비스로 실행 중인 경우
elif systemctl is-active --quiet dcgm-exporter 2>/dev/null; then
  echo "  → systemd 서비스 발견: dcgm-exporter"

  echo "[2/4] 카운터 파일 백업..."
  cp "${COUNTER_FILE}" "${COUNTER_FILE}.bak.$(date +%Y%m%d%H%M%S)"

  echo "[3/4] FAN_SPEED 항목 추가..."
  if grep -q "DCGM_FI_DEV_FAN_SPEED" "${COUNTER_FILE}"; then
    echo "  → 이미 존재합니다. 스킵."
  else
    sed -i "/DCGM_FI_DEV_GPU_TEMP/a ${FAN_ENTRY}" "${COUNTER_FILE}"
    echo "  → 추가 완료."
  fi

  echo "[4/4] dcgm-exporter 서비스 재시작..."
  systemctl restart dcgm-exporter
  echo "  → 재시작 완료."

else
  echo "[!] DCGM exporter 프로세스를 찾을 수 없습니다."
  echo "    수동으로 카운터 파일에 다음 줄을 추가하세요:"
  echo ""
  echo "    ${FAN_ENTRY}"
  echo ""
  echo "    일반적인 카운터 파일 경로:"
  echo "      /etc/dcgm-exporter/default-counters.csv"
  echo "      /usr/local/dcgm/bindings/python3/default-counters.csv"
  exit 1
fi

echo ""
echo "✓ 완료. 30초 후 Prometheus에서 DCGM_FI_DEV_FAN_SPEED 수집 여부 확인:"
echo "  curl http://183.111.14.6:9400/metrics | grep FAN_SPEED"
echo ""
echo "  패시브 쿨링 GPU(A100/H100)는 이 메트릭이 지원되지 않을 수 있습니다."
