#!/usr/bin/env bash
# =============================================================================
# 01-common.sh — 전 노드 공통 설치 (5대 모두 실행)
# 실행 대상: k8s_master1 / k8s_master2 / k8s_master3 / proxy1 / proxy2
# 실행 방법: sudo bash 01-common.sh
# 주의: root 또는 sudo 권한 필요
# =============================================================================
set -euo pipefail

source "$(dirname "$0")/00-env.sh"

echo "=== [01-common] 시작: $(hostname) ==="

# ── 1. 스왑 비활성화 ──────────────────────────────────────────────────────────
# kubelet은 스왑이 활성화된 상태에서 동작하지 않는다
echo "--- [1/8] 스왑 비활성화"
swapoff -a
# /etc/fstab 에서 swap 항목 영구 제거 (재부팅 후에도 유지)
sed -i '/\sswap\s/d' /etc/fstab

# ── 2. 커널 모듈 로드 ─────────────────────────────────────────────────────────
# overlay: containerd 레이어 파일시스템
# br_netfilter: iptables 가 브리지 트래픽을 볼 수 있게 함
echo "--- [2/8] 커널 모듈 설정"
cat <<'EOF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ── 3. sysctl 파라미터 설정 ───────────────────────────────────────────────────
# net.bridge.bridge-nf-call-iptables: 브리지 패킷을 iptables로 전달
# net.ipv4.ip_forward: IP 포워딩 활성화 (Pod 간 통신)
echo "--- [3/8] sysctl 설정"
cat <<'EOF' > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ── 4. apt 의존 패키지 설치 ───────────────────────────────────────────────────
echo "--- [4/8] apt 사전 패키지 설치"
apt-get update -y
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  socat \
  conntrack \
  ipset \
  ipvsadm

# ── 5. containerd 설치 ────────────────────────────────────────────────────────
# Docker 공식 repo 에서 containerd.io 패키지를 설치한다.
# 쿠버네티스 v1.24+ 는 CRI 소켓으로 /run/containerd/containerd.sock 사용.
echo "--- [5/8] containerd 설치"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io="${CONTAINERD_VERSION}"

# containerd 기본 설정 생성 및 SystemdCgroup 활성화
# systemd cgroup 드라이버는 kubelet 과 일치시켜야 한다 (kubeadm 기본값)
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable --now containerd
systemctl restart containerd

# ── 6. kubeadm / kubelet / kubectl 설치 ──────────────────────────────────────
echo "--- [6/8] kubeadm / kubelet / kubectl 설치 (v${K8S_VERSION})"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y \
  kubeadm="${K8S_FULL_VERSION}" \
  kubelet="${K8S_FULL_VERSION}" \
  kubectl="${K8S_FULL_VERSION}"

# 버전 자동 업그레이드 방지
apt-mark hold kubeadm kubelet kubectl containerd.io

# ── 7. kubelet 활성화 ─────────────────────────────────────────────────────────
# kubelet 은 kubeadm init/join 전에 활성화만 해두고 실제 시작은 kubeadm 이 담당
echo "--- [7/8] kubelet 서비스 활성화"
systemctl enable kubelet

# ── 8. /etc/hosts 업데이트 ───────────────────────────────────────────────────
# DNS 없는 환경을 위해 모든 노드 hostname을 /etc/hosts 에 등록
echo "--- [8/8] /etc/hosts 노드 항목 추가"
cat <<EOF >> /etc/hosts

# Kubernetes Cluster Nodes
${MASTER1_IP}  k8s-master1
${MASTER2_IP}  k8s-master2
${MASTER3_IP}  k8s-master3
${PROXY1_IP}   proxy1
${PROXY2_IP}   proxy2
${CONTROL_PLANE_VIP}  k8s-api
EOF

echo "=== [01-common] 완료: $(hostname) ==="
echo "다음 단계:"
echo "  - proxy1/proxy2: 02-haproxy-keepalived.sh 실행"
echo "  - k8s-master1:   03-master1-init.sh 실행"
