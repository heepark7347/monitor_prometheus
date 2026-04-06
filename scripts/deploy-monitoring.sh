#!/usr/bin/env bash
# =============================================================================
# scripts/deploy-monitoring.sh
# monitoring 네임스페이스에 모니터링 스택을 Helm 으로 배포한다.
#
# 전제 조건
#   1. scripts/create-secrets.sh 실행 완료 (Secret 사전 생성)
#   2. local-path-provisioner 설치 완료
#   3. helm repo 등록 완료 (아래 add-repos 서브커맨드 참조)
#
# 사용법:
#   bash scripts/deploy-monitoring.sh add-repos   # 최초 1회
#   bash scripts/deploy-monitoring.sh install     # 전체 설치
#   bash scripts/deploy-monitoring.sh upgrade     # 전체 업그레이드
#   bash scripts/deploy-monitoring.sh <release>   # 단일 릴리즈만
#     릴리즈 이름: postgresql | prometheus | thanos | alertmanager | grafana | snmp-exporter
# =============================================================================

set -euo pipefail

NS=monitoring
HELM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helm/values"

add_repos() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana              https://grafana.github.io/helm-charts
  helm repo add bitnami              https://charts.bitnami.com/bitnami
  helm repo update
  echo "==> Helm repo 등록 완료"
}

deploy_postgresql() {
  echo "==> [1/6] PostgreSQL HA 배포"
  helm upgrade --install postgresql-ha bitnami/postgresql-ha \
    --namespace "${NS}" \
    --values "${HELM_DIR}/postgresql.yaml" \
    --wait --timeout 10m
}

deploy_prometheus() {
  echo "==> [2/6] kube-prometheus-stack 배포 (Prometheus + Operator + node-exporter)"
  helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
    --namespace "${NS}" \
    --values "${HELM_DIR}/prometheus.yaml" \
    --wait --timeout 10m
}

deploy_thanos() {
  echo "==> [3/6] Thanos 배포"
  helm upgrade --install thanos bitnami/thanos \
    --namespace "${NS}" \
    --values "${HELM_DIR}/thanos.yaml" \
    --wait --timeout 10m
}

deploy_alertmanager() {
  echo "==> [4/6] Alertmanager 배포"
  helm upgrade --install alertmanager prometheus-community/alertmanager \
    --namespace "${NS}" \
    --values "${HELM_DIR}/alertmanager.yaml" \
    --wait --timeout 5m
}

deploy_grafana() {
  echo "==> [5/6] Grafana 배포"
  helm upgrade --install grafana grafana/grafana \
    --namespace "${NS}" \
    --values "${HELM_DIR}/grafana.yaml" \
    --wait --timeout 5m
}

deploy_snmp_exporter() {
  echo "==> [6/6] SNMP Exporter 배포"
  helm upgrade --install snmp-exporter prometheus-community/prometheus-snmp-exporter \
    --namespace "${NS}" \
    --values "${HELM_DIR}/snmp-exporter.yaml" \
    --wait --timeout 5m
}

case "${1:-install}" in
  add-repos)
    add_repos
    ;;
  install|upgrade)
    deploy_postgresql
    deploy_prometheus
    deploy_thanos
    deploy_alertmanager
    deploy_grafana
    deploy_snmp_exporter
    echo ""
    echo "==> 전체 배포 완료"
    kubectl get pods -n "${NS}"
    ;;
  postgresql)      deploy_postgresql ;;
  prometheus)      deploy_prometheus ;;
  thanos)          deploy_thanos ;;
  alertmanager)    deploy_alertmanager ;;
  grafana)         deploy_grafana ;;
  snmp-exporter)   deploy_snmp_exporter ;;
  *)
    echo "알 수 없는 인수: $1" >&2
    echo "사용법: $0 {add-repos|install|upgrade|postgresql|prometheus|thanos|alertmanager|grafana|snmp-exporter}" >&2
    exit 1
    ;;
esac
