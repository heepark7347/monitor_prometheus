#!/usr/bin/env bash
# =============================================================================
# 07-label-taint.sh — 노드 레이블 및 테인트 설정
# 실행 대상: k8s_master1 (kubectl 접근 가능한 노드)
# 실행 방법: bash 07-label-taint.sh
# 의존성: 모든 5개 노드 조인 완료 후 실행
#
# 설정 내용:
#   1. 노드 역할 레이블 추가
#   2. master 노드: control-plane taint 유지 (워크로드는 toleration 명시)
#   3. proxy 노드: ingress/snmp 전용 레이블
#   4. 모든 노드에 zone 레이블 (PodAntiAffinity 분산 배치용)
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [07-label-taint] 시작 ==="

# ── 노드명 변수 (kubeadm 이 등록한 hostname 기준) ────────────────────────────
# 실제 노드명이 다를 경우 아래 변수를 수정하세요 (kubectl get nodes 로 확인)
MASTER1_NODE="k8s-master1"
MASTER2_NODE="k8s-master2"
MASTER3_NODE="k8s-master3"
PROXY1_NODE="proxy1"
PROXY2_NODE="proxy2"

# ── 1. 현재 노드 목록 확인 ────────────────────────────────────────────────────
echo "--- [1/4] 현재 노드 목록"
kubectl get nodes -o wide
echo ""

# ── 2. 역할 레이블 설정 ───────────────────────────────────────────────────────
# kubeadm 이 control-plane 레이블을 자동 설정하므로 worker 만 추가
echo "--- [2/4] 역할 레이블 추가"
kubectl label node "${MASTER1_NODE}" node-role.kubernetes.io/worker="" --overwrite
kubectl label node "${MASTER2_NODE}" node-role.kubernetes.io/worker="" --overwrite
kubectl label node "${MASTER3_NODE}" node-role.kubernetes.io/worker="" --overwrite
kubectl label node "${PROXY1_NODE}"  node-role.kubernetes.io/worker="" --overwrite
kubectl label node "${PROXY2_NODE}"  node-role.kubernetes.io/worker="" --overwrite

# ── 3. 존(zone) 레이블 — PodAntiAffinity 분산 배치용 ─────────────────────────
# StatefulSet 의 podAntiAffinity 에서 topology.kubernetes.io/zone 키를 사용해
# master1/2/3 에 각 replica 를 1개씩 분산 배치한다.
echo "--- [3/4] zone 레이블 설정"
kubectl label node "${MASTER1_NODE}" topology.kubernetes.io/zone=zone-a \
  node-type=master --overwrite
kubectl label node "${MASTER2_NODE}" topology.kubernetes.io/zone=zone-b \
  node-type=master --overwrite
kubectl label node "${MASTER3_NODE}" topology.kubernetes.io/zone=zone-c \
  node-type=master --overwrite
kubectl label node "${PROXY1_NODE}"  topology.kubernetes.io/zone=zone-proxy-a \
  node-type=proxy --overwrite
kubectl label node "${PROXY2_NODE}"  topology.kubernetes.io/zone=zone-proxy-b \
  node-type=proxy --overwrite

# ── 4. ingress / snmp-exporter 전용 레이블 ────────────────────────────────────
# proxy 노드에만 ingress-ctrl, snmp-exporter 를 스케줄링하기 위한 nodeSelector 용도
echo "--- [4/4] proxy 노드 전용 레이블"
kubectl label node "${PROXY1_NODE}"  role=ingress-proxy --overwrite
kubectl label node "${PROXY2_NODE}"  role=ingress-proxy --overwrite

# ── 참고: master 테인트 정책 ──────────────────────────────────────────────────
# kubeadm 이 설정한 기본 taint:
#   node-role.kubernetes.io/control-plane:NoSchedule
#
# CLAUDE.md 정책: 테인트를 제거하지 않고 워크로드 toleration 으로 처리
# → prometheus, grafana, postgresql, alertmanager, thanos 모두 아래 toleration 추가 필요:
#
#   tolerations:
#     - key: "node-role.kubernetes.io/control-plane"
#       operator: "Exists"
#       effect: "NoSchedule"
#
# 현재 taint 상태 확인:
echo ""
echo "=== 현재 노드 테인트 확인 ==="
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,TAINTS:.spec.taints[*].key'

echo ""
echo "=== 최종 노드 레이블 확인 ==="
kubectl get nodes --show-labels

echo ""
echo "=== [07-label-taint] 완료 ==="
echo ""
echo "다음 단계:"
echo "  - monitoring namespace 생성: kubectl create namespace monitoring"
echo "  - helm chart 배포: helm/values/ 파일 참조"
