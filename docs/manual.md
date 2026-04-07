# HA Kubernetes 클러스터 + 모니터링 스택 구축 매뉴얼

> **버전** 1.0 · **작성일** 2026-04-07  
> **대상 환경** 온프레미스 VM 5대 / Ubuntu 22.04 / Kubernetes v1.30

---

## 목차

1. [시스템 개요](#1-시스템-개요)
2. [인프라 아키텍처](#2-인프라-아키텍처)
3. [사전 준비사항](#3-사전-준비사항)
4. [Phase 1 — Kubernetes 클러스터 구축](#4-phase-1--kubernetes-클러스터-구축)
5. [Phase 2 — 모니터링 스택 배포](#5-phase-2--모니터링-스택-배포)
6. [배포 결과 확인](#6-배포-결과-확인)
7. [접근 정보](#7-접근-정보)

---

## 1. 시스템 개요

### 컴포넌트 역할

| 구성요소 | 역할 |
|----------|------|
| Prometheus | 메트릭 수집 (2-replica HA) |
| Thanos | 장기 메트릭 저장 및 글로벌 쿼리 |
| Grafana | 시각화 대시보드 (3-replica HA) |
| Alertmanager | 알림 관리 (3-replica HA) |
| PostgreSQL | Grafana 세션/설정 DB |
| MinIO | Thanos 오브젝트 스토리지 (S3-compatible) |
| SNMP Exporter | 네트워크 장비 메트릭 수집 |
| node-exporter | 노드 시스템 메트릭 (DaemonSet) |
| nginx-ingress | 외부 트래픽 진입점 (DaemonSet) |

### 소프트웨어 버전

| 소프트웨어 | 버전 |
|-----------|------|
| Kubernetes | v1.30.0 |
| containerd | v1.7.22 |
| Calico CNI | v3.28.0 |
| Helm | v3.20.1 |
| nginx-ingress-controller | v1.10.1 |

---

## 2. 인프라 아키텍처

### 노드 구성

| 호스트 | IP | 역할 | Zone |
|--------|----|------|------|
| k8s-master1 | 10.10.120.232 | Control Plane + Worker | zone-a |
| k8s-master2 | 10.10.120.233 | Control Plane + Worker | zone-b |
| k8s-master3 | 10.10.120.234 | Control Plane + Worker | zone-c |
| proxy1 | 10.10.120.230 | Worker (ingress / snmp) | zone-proxy-a |
| proxy2 | 10.10.120.231 | Worker (ingress / snmp) | zone-proxy-b |

### 네트워크 구성

```
외부 트래픽 (HTTP :80)
       │
       ▼
keepalived VIP: 10.10.120.220
       │
       ├── proxy1 (10.10.120.230) MASTER priority 101
       └── proxy2 (10.10.120.231) BACKUP priority 100
              │  HAProxy :6443
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
master1:6443  master2:6443  master3:6443
```

| 파라미터 | 값 |
|---------|----|
| Control Plane VIP | 10.10.120.220 |
| API 서버 포트 | 6443 |
| Pod CIDR | 192.168.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| CNI | Calico v3.28.0 (VXLAN CrossSubnet) |
| kube-proxy 모드 | ipvs |
| CRI | containerd v1.7.22 |

### HA 구조

- **Control Plane**: kubeadm stacked etcd, HAProxy 라운드로빈, keepalived VRRP
- **워크로드 분산**: 모든 StatefulSet은 `topology.kubernetes.io/zone` 기준 master 3대에 1 replica씩 분산

### 모니터링 스택 흐름

```
Prometheus-0/1 (Thanos sidecar)
       │
       ▼
Thanos StoreGateway (×3) ←→ MinIO (S3)
       │                         ↑
       ▼               Thanos Compactor
Thanos Query (×3)
       │
Thanos QueryFrontend
       │
   Grafana (×3) ← PostgreSQL
```

---

## 3. 사전 준비사항

### OS 요구사항

- Ubuntu 22.04 LTS (5대 모두)
- root 또는 sudo 권한
- 인터넷 접근 (패키지 다운로드)

### SSH 접근 설정

```bash
# ed25519 키 생성
ssh-keygen -t ed25519 -f ~/.ssh/k8s_cluster

# 각 노드에 공개키 배포
for HOST in 10.10.120.230 10.10.120.231 10.10.120.232 10.10.120.233 10.10.120.234; do
  ssh-copy-id -i ~/.ssh/k8s_cluster.pub ubuntu@${HOST}
done
```

`~/.ssh/config`:

```
Host k8s-master1
  HostName 10.10.120.232
  User ubuntu
  IdentityFile ~/.ssh/k8s_cluster

Host k8s-master2
  HostName 10.10.120.233
  User ubuntu
  IdentityFile ~/.ssh/k8s_cluster

Host k8s-master3
  HostName 10.10.120.234
  User ubuntu
  IdentityFile ~/.ssh/k8s_cluster

Host proxy1
  HostName 10.10.120.230
  User ubuntu
  IdentityFile ~/.ssh/k8s_cluster

Host proxy2
  HostName 10.10.120.231
  User ubuntu
  IdentityFile ~/.ssh/k8s_cluster
```

### 레포 클론

```bash
git clone <repo-url>
cd <repo-dir>
```

---

## 4. Phase 1 — Kubernetes 클러스터 구축

### 전체 실행 순서

```
전 노드(5대): 01-common.sh
proxy1/2    : 02-haproxy-keepalived.sh
master1     : 03-master1-init.sh → 06-calico.sh
master2/3   : 04-master-join.sh
proxy1/2    : 05-worker-join.sh
master1     : 07-label-taint.sh → 08-post-install.sh
```

---

### Step 1. 공통 설치 — 전 노드 5대

```bash
sudo bash scripts/k8s-install/01-common.sh
```

| 단계 | 작업 |
|------|------|
| 1 | 스왑 영구 비활성화 |
| 2 | 커널 모듈 로드 (`overlay`, `br_netfilter`) |
| 3 | sysctl 설정 (IP forwarding, bridge netfilter) |
| 4 | apt 패키지 설치 (`socat`, `conntrack`, `ipset`, `ipvsadm`) |
| 5 | containerd v1.7.22 설치 + SystemdCgroup 활성화 |
| 6 | kubeadm / kubelet / kubectl v1.30.0 설치 및 버전 고정 |
| 7 | kubelet 서비스 활성화 |
| 8 | `/etc/hosts` 노드 항목 추가 |

---

### Step 2. HAProxy / keepalived — proxy1, proxy2

```bash
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy1  # proxy1에서
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy2  # proxy2에서
```

설정 파일:

| 파일 | 설명 |
|------|------|
| `configs/haproxy/haproxy.cfg` | TCP 로드밸런서 (API :6443) |
| `configs/keepalived/keepalived-proxy1.conf` | VRRP MASTER (priority 101) |
| `configs/keepalived/keepalived-proxy2.conf` | VRRP BACKUP (priority 100) |

완료 확인:

```bash
# proxy1에서 VIP 바인딩 확인
ip addr show enX0 | grep 10.10.120.220
```

---

### Step 3. master1 클러스터 초기화

```bash
sudo bash scripts/k8s-install/03-master1-init.sh
```

- VIP 접근 사전 검사 후 `kubeadm init` 실행
- kubeconfig → `~/.kube/config` 자동 구성
- Join 명령어 → `scripts/k8s-install/join-tokens/` 저장

> Join 토큰은 **24시간 후 만료**. 만료 시 `sudo kubeadm init phase upload-certs --upload-certs`로 재발급.

---

### Step 4. Calico CNI 설치 — master1

```bash
bash scripts/k8s-install/06-calico.sh
```

> **반드시 master2/3 조인 전에 실행.** CNI 미설치 시 CoreDNS Pending 상태.

완료 확인:

```bash
kubectl get pods -n calico-system
# 모든 Pod Ready 후 다음 단계 진행
```

---

### Step 5. master2 / master3 조인 (Control Plane)

```bash
# master1에서 join 명령 확인
cat scripts/k8s-install/join-tokens/kubeadm-init-full.log | grep -A 10 "control-plane"

# master2, master3 각각에서 실행
export CONTROL_PLANE_JOIN_CMD="<위 출력의 kubeadm join 명령어>"
sudo -E bash scripts/k8s-install/04-master-join.sh
```

완료 확인:

```bash
kubectl get nodes
# k8s-master1/2/3 모두 Ready
```

---

### Step 6. proxy 워커 노드 조인

```bash
# master1에서 worker join 명령 생성
kubeadm token create --print-join-command

# proxy1, proxy2 각각에서 실행
export WORKER_JOIN_CMD="<위 출력값>"
sudo -E bash scripts/k8s-install/05-worker-join.sh
```

---

### Step 7. 노드 레이블 및 테인트 설정 — master1

```bash
bash scripts/k8s-install/07-label-taint.sh
```

| 노드 | 설정 레이블 |
|------|------------|
| master1/2/3 | `topology.kubernetes.io/zone=zone-a/b/c`, `node-type=master` |
| proxy1/2 | `topology.kubernetes.io/zone=zone-proxy-a/b`, `node-type=proxy`, `role=ingress-proxy` |

> master의 `control-plane:NoSchedule` taint는 유지. 워크로드는 toleration으로 처리.

---

### Step 8. 사후 설치 — master1

```bash
bash scripts/k8s-install/08-post-install.sh
```

- `monitoring` namespace 생성
- Helm v3 설치 확인 (미설치 시 자동 설치)

**Phase 1 완료 상태**:

```
NAME          STATUS   ROLES                  VERSION   INTERNAL-IP
k8s-master1   Ready    control-plane,worker   v1.30.0   10.10.120.232
k8s-master2   Ready    control-plane,worker   v1.30.0   10.10.120.233
k8s-master3   Ready    control-plane,worker   v1.30.0   10.10.120.234
proxy1        Ready    worker                 v1.30.0   10.10.120.230
proxy2        Ready    worker                 v1.30.0   10.10.120.231
```

---

## 5. Phase 2 — 모니터링 스택 배포

### Step 1. 스토리지 프로비저너 설치

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml

kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
```

---

### Step 2. Secret 생성

```bash
export GRAFANA_ADMIN_PASSWORD="<관리자 비밀번호>"
export GRAFANA_DB_PASSWORD="<Grafana DB 비밀번호>"
export PG_ADMIN_PASSWORD="<PostgreSQL admin 비밀번호>"
export PG_REPMGR_PASSWORD="<repmgr 비밀번호>"
export PG_PGPOOL_PASSWORD="<pgpool 비밀번호>"
export THANOS_OBJSTORE_BUCKET="thanos"
export THANOS_OBJSTORE_ENDPOINT="minio.monitoring.svc:9000"
export THANOS_OBJSTORE_ACCESS_KEY="<MinIO access key>"
export THANOS_OBJSTORE_SECRET_KEY="<MinIO secret key>"

bash scripts/create-secrets.sh
```

생성되는 Secret:

| Secret | 내용 |
|--------|------|
| `grafana-db-secret` | Grafana admin + DB 비밀번호 |
| `postgresql-ha-secret` | PostgreSQL / repmgr / pgpool 비밀번호 |
| `thanos-objstore-secret` | MinIO S3 접속 정보 |

---

### Step 3. MinIO 설치

```bash
helm repo add minio https://charts.min.io/
helm repo update

helm upgrade --install minio minio/minio \
  --namespace monitoring \
  --values helm/values/minio.yaml \
  --wait --timeout 5m

# thanos 버킷 생성
kubectl exec -n monitoring deploy/minio-minio -- mc mb local/thanos
```

---

### Step 4. 모니터링 스택 Helm 배포

```bash
# Helm repo 등록 (최초 1회)
bash scripts/deploy-monitoring.sh add-repos

# 전체 배포
bash scripts/deploy-monitoring.sh install
```

배포 순서:

| 순서 | 릴리즈 | Chart | values |
|------|--------|-------|--------|
| 1 | postgresql-ha | bitnami/postgresql-ha | `helm/values/postgresql.yaml` |
| 2 | kube-prometheus | prometheus-community/kube-prometheus-stack | `helm/values/prometheus.yaml` |
| 3 | thanos | bitnami/thanos | `helm/values/thanos.yaml` |
| 4 | alertmanager | prometheus-community/alertmanager | `helm/values/alertmanager.yaml` |
| 5 | grafana | grafana/grafana | `helm/values/grafana.yaml` |
| 6 | snmp-exporter | prometheus-community/prometheus-snmp-exporter | `helm/values/snmp-exporter.yaml` |

---

### Step 5. nginx-ingress 설치

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace monitoring \
  --values helm/values/nginx-ingress.yaml \
  --wait --timeout 5m
```

- proxy1/2에 DaemonSet 배포, `hostNetwork: true`
- VIP `10.10.120.220:80` → proxy1/2 → Grafana

### Step 6. Grafana Ingress 배포

```bash
kubectl apply -f k8s/services/grafana-ingress.yaml
```

---

## 6. 배포 결과 확인

```bash
kubectl get pods -n monitoring -o wide
```

| 컴포넌트 | 파드 수 | 배치 노드 |
|----------|--------|---------|
| Prometheus | 2 (3/3) | master1, master2 |
| Alertmanager | 3 | master1, master2, master3 |
| Grafana | 3 | master1, master2, master3 |
| Thanos StoreGateway | 3 | master1, master2, master3 |
| Thanos Query | 3 | master1, master2, master3 |
| Thanos QueryFrontend | 1 | master1 |
| Thanos Compactor | 1 | master3 |
| MinIO | 4 | master1, master2, master3 |
| PostgreSQL | 1 | master1 |
| SNMP Exporter | 2 | proxy1, proxy2 |
| node-exporter | 5 (DaemonSet) | 전 노드 |
| nginx-ingress | 2 (DaemonSet) | proxy1, proxy2 |

```bash
# PVC 상태 확인
kubectl get pvc -n monitoring

# StatefulSet 분산 배치 확인
kubectl get pods -n monitoring -o wide | grep -E 'grafana|prometheus|alertmanager|thanos-store'
```

---

## 7. 접근 정보

### Grafana

| 항목 | 값 |
|------|----|
| URL | `http://10.10.120.220/` |
| 계정 | `admin` |
| 비밀번호 | `GRAFANA_ADMIN_PASSWORD` 설정값 |

### 내부 서비스 (port-forward)

```bash
# Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-prometheus 9090:9090

# Thanos Query UI
kubectl port-forward -n monitoring svc/thanos-query 10902:10902

# Alertmanager UI
kubectl port-forward -n monitoring svc/alertmanager 9093:9093

# MinIO Console
kubectl port-forward -n monitoring svc/minio 9001:9001
```

---

## 부록 — 레포 구조

```
.
├── configs/
│   ├── haproxy/haproxy.cfg
│   ├── keepalived/keepalived-proxy1.conf
│   ├── keepalived/keepalived-proxy2.conf
│   └── kubeadm/kubeadm-init.yaml
├── helm/values/
│   ├── prometheus.yaml
│   ├── thanos.yaml
│   ├── grafana.yaml
│   ├── alertmanager.yaml
│   ├── postgresql.yaml
│   ├── minio.yaml
│   ├── snmp-exporter.yaml
│   └── nginx-ingress.yaml
├── k8s/services/grafana-ingress.yaml
└── scripts/
    ├── create-secrets.sh
    ├── deploy-monitoring.sh
    └── k8s-install/
        ├── 00-env.sh
        ├── 01-common.sh
        ├── 02-haproxy-keepalived.sh
        ├── 03-master1-init.sh
        ├── 04-master-join.sh
        ├── 05-worker-join.sh
        ├── 06-calico.sh
        ├── 07-label-taint.sh
        └── 08-post-install.sh
```
