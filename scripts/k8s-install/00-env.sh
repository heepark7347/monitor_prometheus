#!/usr/bin/env bash
# =============================================================================
# 00-env.sh — 전 노드 공통 환경 변수 정의
# 모든 설치 스크립트에서 source 하여 사용한다.
# 사용법: source ./00-env.sh
# =============================================================================

# ── Kubernetes 버전 ────────────────────────────────────────────────────────────
export K8S_VERSION="1.30"                     # apt 패키지 채널 버전
export K8S_FULL_VERSION="1.30.0-1.1"          # 정확한 패키지 버전 (kubeadm/kubelet/kubectl)
export KUBEADM_K8S_VERSION="v1.30.0"          # kubeadm init 에 전달할 버전

# ── 컨테이너 런타임 ────────────────────────────────────────────────────────────
export CONTAINERD_VERSION="1.7.22-1"          # apt containerd.io 패키지 버전

# ── 네트워크 ──────────────────────────────────────────────────────────────────
export CONTROL_PLANE_VIP="10.10.120.220"      # keepalived VIP (API 서버 LB 주소)
export CONTROL_PLANE_PORT="6443"              # k8s API 서버 포트
export POD_CIDR="192.168.0.0/16"             # Calico 기본 Pod CIDR
export SERVICE_CIDR="10.96.0.0/12"           # kube-proxy 서비스 CIDR

# ── 노드 IP ───────────────────────────────────────────────────────────────────
export MASTER1_IP="10.10.120.232"
export MASTER2_IP="10.10.120.233"
export MASTER3_IP="10.10.120.234"
export PROXY1_IP="10.10.120.230"
export PROXY2_IP="10.10.120.231"

# ── Calico ────────────────────────────────────────────────────────────────────
export CALICO_VERSION="v3.28.0"

# ── keepalived VIP 인터페이스 (proxy 노드의 실제 NIC 이름으로 변경 필요) ──────
export VIP_INTERFACE="enX0"                   # proxy1/proxy2 실제 NIC 이름

# ── keepalived 우선순위 ────────────────────────────────────────────────────────
export KEEPALIVED_PRIORITY_PROXY1="101"       # MASTER 역할
export KEEPALIVED_PRIORITY_PROXY2="100"       # BACKUP 역할

# ── namespace ─────────────────────────────────────────────────────────────────
export MONITORING_NS="monitoring"
