#!/usr/bin/env bash
# =============================================================================
# scripts/create-secrets.sh
# monitoring namespace 에 필요한 Secret 을 모두 생성한다.
# 실행 전: 아래 변수를 환경변수로 export 하거나 직접 수정할 것.
#
# 사용법:
#   export GRAFANA_ADMIN_PASSWORD="..."
#   export GRAFANA_DB_PASSWORD="..."
#   export PG_ADMIN_PASSWORD="..."
#   export PG_REPMGR_PASSWORD="..."
#   export PG_PGPOOL_PASSWORD="..."
#   export THANOS_OBJSTORE_BUCKET="..."    # MinIO/S3 버킷명
#   export THANOS_OBJSTORE_ENDPOINT="..."  # e.g. minio.monitoring.svc:9000
#   export THANOS_OBJSTORE_ACCESS_KEY="..."
#   export THANOS_OBJSTORE_SECRET_KEY="..."
#   bash scripts/create-secrets.sh
# =============================================================================

set -euo pipefail

NS=monitoring

check_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[ERROR] 환경변수 $name 이 설정되지 않았습니다." >&2
    exit 1
  fi
}

check_var GRAFANA_ADMIN_PASSWORD
check_var GRAFANA_DB_PASSWORD
check_var PG_ADMIN_PASSWORD
check_var PG_REPMGR_PASSWORD
check_var PG_PGPOOL_PASSWORD
check_var THANOS_OBJSTORE_BUCKET
check_var THANOS_OBJSTORE_ENDPOINT
check_var THANOS_OBJSTORE_ACCESS_KEY
check_var THANOS_OBJSTORE_SECRET_KEY

# ── 1. Grafana DB + Admin Secret ──────────────────────────────────────────────
echo "==> grafana-db-secret 생성"
kubectl create secret generic grafana-db-secret \
  --namespace="${NS}" \
  --from-literal=GF_SECURITY_ADMIN_USER=admin \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}" \
  --from-literal=GF_DATABASE_PASSWORD="${GRAFANA_DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 2. PostgreSQL HA Secret ───────────────────────────────────────────────────
echo "==> postgresql-ha-secret 생성"
kubectl create secret generic postgresql-ha-secret \
  --namespace="${NS}" \
  --from-literal=postgresql-password="${PG_ADMIN_PASSWORD}" \
  --from-literal=repmgr-password="${PG_REPMGR_PASSWORD}" \
  --from-literal=pgpool-admin-password="${PG_PGPOOL_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Thanos Object Storage Secret ──────────────────────────────────────────
echo "==> thanos-objstore-secret 생성"
OBJSTORE_YAML=$(cat <<EOF
type: S3
config:
  bucket: "${THANOS_OBJSTORE_BUCKET}"
  endpoint: "${THANOS_OBJSTORE_ENDPOINT}"
  access_key: "${THANOS_OBJSTORE_ACCESS_KEY}"
  secret_key: "${THANOS_OBJSTORE_SECRET_KEY}"
  insecure: true
EOF
)

kubectl create secret generic thanos-objstore-secret \
  --namespace="${NS}" \
  --from-literal=objstore.yml="${OBJSTORE_YAML}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "==> 모든 Secret 생성 완료"
kubectl get secrets -n "${NS}" | grep -E 'grafana-db|postgresql-ha|thanos-objstore'
