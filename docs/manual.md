# HA Kubernetes 클러스터 + 모니터링 스택 구축 매뉴얼

> **버전** 1.0 · **작성일** 2026-04-07  
> **대상 환경** 온프레미스 VM 5대 / Ubuntu / Kubernetes v1.30

---

## 목차

1. [시스템 개요](#1-시스템-개요)
2. [인프라 아키텍처](#2-인프라-아키텍처)
3. [사전 준비사항](#3-사전-준비사항)
4. [Phase 1 — Kubernetes 클러스터 구축](#4-phase-1--kubernetes-클러스터-구축)
   - 4.1 공통 설치 (전 노드)
   - 4.2 HAProxy / keepalived 설정
   - 4.3 master1 클러스터 초기화
   - 4.4 Calico CNI 설치
   - 4.5 master2 / master3 조인
   - 4.6 proxy 워커 노드 조인
   - 4.7 노드 레이블 및 테인트 설정
   - 4.8 사후 설치 작업
5. [Phase 2 — 모니터링 스택 배포](#5-phase-2--모니터링-스택-배포)
   - 5.1 스토리지 프로비저너 설치
   - 5.2 Secret 생성
   - 5.3 MinIO 설치 (오브젝트 스토리지)
   - 5.4 Helm 차트 배포
   - 5.5 nginx-ingress + Grafana 외부 접근
6. [배포 결과 확인](#6-배포-결과-확인)
7. [접근 정보](#7-접근-정보)
8. [트러블슈팅](#8-트러블슈팅)
9. [보안 원칙](#9-보안-원칙)
10. [부록 — 레포 구조](#10-부록--레포-구조)

---

## 1. 시스템 개요

### 목적

온프레미스 VM 5대를 기반으로 고가용성(HA) Kubernetes 클러스터를 구성하고,
그 위에 아래 모니터링 스택을 배포합니다.

| 구성요소 | 역할 |
|----------|------|
| **Prometheus** | 메트릭 수집 (2-replica HA) |
| **Thanos** | 장기 메트릭 저장 및 글로벌 쿼리 |
| **Grafana** | 시각화 대시보드 (3-replica HA) |
| **Alertmanager** | 알림 관리 (3-replica HA) |
| **PostgreSQL** | Grafana 세션/설정 DB |
| **MinIO** | Thanos 오브젝트 스토리지 (S3-compatible) |
| **SNMP Exporter** | 네트워크 장비 메트릭 수집 |
| **node-exporter** | 노드 시스템 메트릭 (DaemonSet) |
| **nginx-ingress** | 외부 트래픽 진입점 (DaemonSet) |

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

### 2.1 노드 구성

| 호스트 | IP | 역할 | Zone |
|--------|----|------|------|
| k8s-master1 | 10.10.120.232 | Control Plane + Worker | zone-a |
| k8s-master2 | 10.10.120.233 | Control Plane + Worker | zone-b |
| k8s-master3 | 10.10.120.234 | Control Plane + Worker | zone-c |
| proxy1 | 10.10.120.230 | Worker (ingress / snmp) | zone-proxy-a |
| proxy2 | 10.10.120.231 | Worker (ingress / snmp) | zone-proxy-b |

- master 3대: `node-role.kubernetes.io/control-plane:NoSchedule` taint 유지
- proxy 2대: taint 없음, `node-type=proxy` / `role=ingress-proxy` 레이블

### 2.2 네트워크 구성

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

### 2.3 HA 구조

**Control Plane HA**
- kubeadm stacked etcd: etcd가 각 master 노드에 내장
- HAProxy(proxy1/2) → VIP → master1/2/3 라운드로빈
- keepalived VRRP: proxy1 MASTER, proxy2 BACKUP

**워크로드 분산 배치**
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: <app-name>
        topologyKey: "topology.kubernetes.io/zone"
```

모든 StatefulSet(Prometheus, Grafana, Alertmanager, Thanos StoreGateway 등)은
`topology.kubernetes.io/zone` 기준 master 3대에 1 replica씩 분산 배치됩니다.

### 2.4 모니터링 스택 아키텍처

```
┌─────────────────────────────────────────────────────┐
│                  monitoring namespace                 │
│                                                       │
│  Prometheus-0  Prometheus-1                           │
│       │              │  (Thanos sidecar)              │
│       └──────┬───────┘                               │
│              ▼                                        │
│  Thanos StoreGateway (×3)                            │
│         ▼                                             │
│  MinIO (S3) ← Thanos Compactor                       │
│         ▼                                             │
│  Thanos Query (×3) → Thanos QueryFrontend            │
│              ▼                                        │
│           Grafana (×3) ← PostgreSQL                  │
│                                                       │
│  Alertmanager (×3) ← Prometheus rules                │
│  node-exporter (×5, DaemonSet)                       │
│  SNMP Exporter (×2, proxy 노드)                      │
└─────────────────────────────────────────────────────┘
```

---

## 3. 사전 준비사항

### 3.1 OS 요구사항

- Ubuntu 22.04 LTS (5대 모두)
- root 또는 sudo 권한
- 인터넷 접근 (패키지 다운로드)

### 3.2 SSH 접근 설정

```bash
# 관리 서버에서 SSH 키 생성 (ed25519)
ssh-keygen -t ed25519 -f ~/.ssh/k8s_cluster

# 각 노드에 공개키 배포
for HOST in 10.10.120.230 10.10.120.231 10.10.120.232 10.10.120.233 10.10.120.234; do
  ssh-copy-id -i ~/.ssh/k8s_cluster.pub user@${HOST}
done
```

`~/.ssh/config` 예시:

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

### 3.3 레포 클론

```bash
# 관리 서버 및 master1에서
git clone <repo-url>
cd <repo-dir>
```

---

## 4. Phase 1 — Kubernetes 클러스터 구축

### 전체 실행 순서 요약

```
전 노드(5대): 01-common.sh
proxy1/2    : 02-haproxy-keepalived.sh
master1     : 03-master1-init.sh → 06-calico.sh
master2/3   : 04-master-join.sh (control-plane)
proxy1/2    : 05-worker-join.sh
master1     : 07-label-taint.sh → 08-post-install.sh
```

---

### 4.1 공통 설치 (전 노드 5대)

**스크립트**: `scripts/k8s-install/01-common.sh`

```bash
# 5대 노드 모두에서 실행
sudo bash scripts/k8s-install/01-common.sh
```

**수행 내용**:

| 단계 | 작업 |
|------|------|
| 1 | 스왑 영구 비활성화 (`/etc/fstab` 수정) |
| 2 | 커널 모듈 로드 (`overlay`, `br_netfilter`) |
| 3 | sysctl 파라미터 설정 (IP forwarding, bridge netfilter) |
| 4 | apt 의존 패키지 설치 (`socat`, `conntrack`, `ipset`, `ipvsadm`) |
| 5 | containerd v1.7.22 설치 + SystemdCgroup 활성화 |
| 6 | kubeadm / kubelet / kubectl v1.30.0 설치 및 버전 고정 |
| 7 | kubelet 서비스 활성화 |
| 8 | `/etc/hosts` 노드 항목 추가 |

> **중요**: `apt-mark hold`로 버전 고정되어 `apt upgrade`로 자동 업그레이드되지 않습니다.

---

### 4.2 HAProxy / keepalived 설정

**스크립트**: `scripts/k8s-install/02-haproxy-keepalived.sh`

```bash
# proxy1에서 실행
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy1

# proxy2에서 실행
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy2
```

**설정 파일 위치**:

| 파일 | 설명 |
|------|------|
| `configs/haproxy/haproxy.cfg` | HAProxy 설정 (TCP 로드밸런서, API :6443) |
| `configs/keepalived/keepalived-proxy1.conf` | VRRP MASTER (priority 101) |
| `configs/keepalived/keepalived-proxy2.conf` | VRRP BACKUP (priority 100) |

**완료 확인**:

```bash
# VIP 활성화 확인 (proxy1에서)
ip addr show enX0 | grep 10.10.120.220

# HAProxy 상태 확인
systemctl status haproxy

# keepalived 상태 확인
systemctl status keepalived
```

> **주의**: NIC 이름은 실제 환경에 맞게 확인 필요. 본 구축에서는 `enX0` 사용.

---

### 4.3 master1 클러스터 초기화

**스크립트**: `scripts/k8s-install/03-master1-init.sh`

```bash
# k8s-master1에서 실행
sudo bash scripts/k8s-install/03-master1-init.sh
```

**수행 내용**:

1. VIP 접근 사전 검사 (`nc -zv 10.10.120.220 6443`)
2. `kubeadm config images pull` (컨테이너 이미지 사전 다운로드)
3. `kubeadm init --config configs/kubeadm/kubeadm-init.yaml --upload-certs`
4. `~/.kube/config` 자동 구성
5. Join 명령어 `scripts/k8s-install/join-tokens/` 에 저장

**kubeadm-init.yaml 주요 설정**:

```yaml
controlPlaneEndpoint: "10.10.120.220:6443"  # VIP 주소
networking:
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/12"
kubernetesVersion: "v1.30.0"
```

> **중요**: Join 토큰은 24시간 후 만료됩니다.  
> 만료 시 `sudo kubeadm init phase upload-certs --upload-certs`로 재발급.

---

### 4.4 Calico CNI 설치

**스크립트**: `scripts/k8s-install/06-calico.sh`

```bash
# k8s-master1에서 실행 (master1 init 직후, master2/3 조인 전에 실행)
bash scripts/k8s-install/06-calico.sh
```

- Calico v3.28.0 Tigera Operator 방식
- CNI 미설치 시 CoreDNS가 Pending 상태로 남음

**완료 확인**:

```bash
kubectl get pods -n calico-system
# 모든 Pod Ready 상태 확인 후 다음 단계 진행
```

---

### 4.5 master2 / master3 조인 (Control Plane)

**스크립트**: `scripts/k8s-install/04-master-join.sh`

```bash
# master1에서 join 명령 확인
cat scripts/k8s-install/join-tokens/kubeadm-init-full.log \
  | grep -A 10 "control-plane"

# k8s-master2에서 실행
export CONTROL_PLANE_JOIN_CMD="<03 출력의 kubeadm join 명령어>"
sudo -E bash scripts/k8s-install/04-master-join.sh

# k8s-master3에서 동일하게 실행
sudo -E bash scripts/k8s-install/04-master-join.sh
```

**완료 확인 (master1에서)**:

```bash
kubectl get nodes
# NAME          STATUS   ROLES                  VERSION
# k8s-master1   Ready    control-plane,worker   v1.30.0
# k8s-master2   Ready    control-plane,worker   v1.30.0
# k8s-master3   Ready    control-plane,worker   v1.30.0
```

---

### 4.6 proxy 워커 노드 조인

**스크립트**: `scripts/k8s-install/05-worker-join.sh`

```bash
# master1에서 worker join 명령 생성
kubeadm token create --print-join-command

# proxy1에서 실행
export WORKER_JOIN_CMD="<위 명령어 출력>"
sudo -E bash scripts/k8s-install/05-worker-join.sh

# proxy2에서 동일하게 실행
sudo -E bash scripts/k8s-install/05-worker-join.sh
```

**완료 확인**:

```bash
kubectl get nodes
# 5대 모두 Ready 상태 확인
```

---

### 4.7 노드 레이블 및 테인트 설정

**스크립트**: `scripts/k8s-install/07-label-taint.sh`

```bash
# k8s-master1에서 실행 (5대 모두 조인 완료 후)
bash scripts/k8s-install/07-label-taint.sh
```

**설정되는 레이블**:

| 노드 | 레이블 |
|------|--------|
| k8s-master1/2/3 | `topology.kubernetes.io/zone=zone-a/b/c`, `node-type=master` |
| proxy1/2 | `topology.kubernetes.io/zone=zone-proxy-a/b`, `node-type=proxy`, `role=ingress-proxy` |

> master 노드의 `control-plane:NoSchedule` taint는 제거하지 않습니다.  
> 모니터링 워크로드는 toleration으로 스케줄링됩니다.

---

### 4.8 사후 설치 작업

**스크립트**: `scripts/k8s-install/08-post-install.sh`

```bash
# k8s-master1에서 실행
bash scripts/k8s-install/08-post-install.sh
```

**수행 내용**:

1. `monitoring` namespace 생성
2. Helm v3 설치 확인 (미설치 시 자동 설치)
3. 최종 클러스터 상태 출력

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

### 5.1 스토리지 프로비저너 설치

StatefulSet PVC에 사용할 local-path StorageClass를 설치합니다.

```bash
# k8s-master1에서 실행
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml

# default StorageClass로 설정
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

# 확인
kubectl get storageclass
```

---

### 5.2 Secret 생성

**스크립트**: `scripts/create-secrets.sh`

```bash
# 환경변수 설정 후 실행
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

**생성되는 Secret**:

| Secret 이름 | 내용 |
|------------|------|
| `grafana-db-secret` | Grafana admin 계정 + DB 비밀번호 |
| `postgresql-ha-secret` | PostgreSQL / repmgr / pgpool 비밀번호 |
| `thanos-objstore-secret` | MinIO S3 접속 정보 (`objstore.yml`) |

---

### 5.3 MinIO 설치 (오브젝트 스토리지)

Thanos 장기 저장소로 사용하는 S3-compatible 오브젝트 스토리지입니다.

```bash
# helm repo 등록 (최초 1회)
helm repo add minio https://charts.min.io/
helm repo update

# MinIO 배포
helm upgrade --install minio minio/minio \
  --namespace monitoring \
  --values helm/values/minio.yaml \
  --wait --timeout 5m

# thanos 버킷 생성
kubectl exec -n monitoring deploy/minio-minio -- \
  mc mb local/thanos
```

---

### 5.4 Helm 차트 배포

**스크립트**: `scripts/deploy-monitoring.sh`

```bash
# Helm repo 등록 (최초 1회)
bash scripts/deploy-monitoring.sh add-repos

# 전체 배포 (순서 보장)
bash scripts/deploy-monitoring.sh install
```

**배포 순서 및 values 파일**:

| 순서 | 릴리즈명 | Chart | values 파일 |
|------|---------|-------|------------|
| 1 | postgresql-ha | bitnami/postgresql-ha | `helm/values/postgresql.yaml` |
| 2 | kube-prometheus | prometheus-community/kube-prometheus-stack | `helm/values/prometheus.yaml` |
| 3 | thanos | bitnami/thanos | `helm/values/thanos.yaml` |
| 4 | alertmanager | prometheus-community/alertmanager | `helm/values/alertmanager.yaml` |
| 5 | grafana | grafana/grafana | `helm/values/grafana.yaml` |
| 6 | snmp-exporter | prometheus-community/prometheus-snmp-exporter | `helm/values/snmp-exporter.yaml` |

**개별 컴포넌트 배포**:

```bash
# 단일 컴포넌트만 재배포 시
bash scripts/deploy-monitoring.sh prometheus
bash scripts/deploy-monitoring.sh grafana
bash scripts/deploy-monitoring.sh thanos
# ... 등
```

---

### 5.5 nginx-ingress + Grafana 외부 접근

#### nginx-ingress 설치

```bash
# helm repo 등록
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# DaemonSet으로 proxy 노드에 배포
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace monitoring \
  --values helm/values/nginx-ingress.yaml \
  --wait --timeout 5m
```

**구성**:
- proxy1 / proxy2에 DaemonSet으로 배포
- `hostNetwork: true` 사용 — VIP(keepalived)가 `enX0`에 바인딩
- `Service: disabled` — hostNetwork 사용으로 불필요

#### Grafana Ingress 배포

```bash
kubectl apply -f k8s/services/grafana-ingress.yaml
```

**트래픽 흐름**:

```
외부 클라이언트 → VIP 10.10.120.220:80
  → proxy1/2 nginx-ingress (hostNetwork)
  → grafana Service (ClusterIP)
  → grafana-0/1/2 Pod
```

---

## 6. 배포 결과 확인

### 파드 상태 확인

```bash
kubectl get pods -n monitoring -o wide
```

**정상 상태**:

| 컴포넌트 | 파드 수 | 배치 노드 |
|----------|--------|---------|
| Prometheus | 2 (Running 3/3) | master1, master2 |
| Alertmanager | 3 (Running) | master1, master2, master3 |
| Grafana | 3 (Running) | master1, master2, master3 |
| Thanos StoreGateway | 3 (Running) | master1, master2, master3 |
| Thanos Query | 3 (Running) | master1, master2, master3 |
| Thanos QueryFrontend | 1 (Running) | master1 |
| Thanos Compactor | 1 (Running) | master3 |
| MinIO | 4 (Running) | master1, master2, master3 |
| PostgreSQL | 1 (Running) | master1 |
| SNMP Exporter | 2 (Running) | proxy1, proxy2 |
| node-exporter | 5 (DaemonSet) | 전 노드 |
| nginx-ingress | 2 (DaemonSet) | proxy1, proxy2 |

### 노드 분산 확인

```bash
# 각 StatefulSet의 파드가 다른 노드에 배치됐는지 확인
kubectl get pods -n monitoring -o wide | grep -E 'grafana|prometheus|alertmanager|thanos-store'
```

### PVC 상태 확인

```bash
kubectl get pvc -n monitoring
# 모든 PVC Bound 상태 확인
```

---

## 7. 접근 정보

### Grafana 대시보드

| 항목 | 값 |
|------|----|
| URL | `http://<VIP 또는 공인IP>/` |
| 기본 계정 | `admin` |
| 비밀번호 | `create-secrets.sh` 실행 시 설정한 `GRAFANA_ADMIN_PASSWORD` |

### 내부 서비스 접근 (kubectl port-forward)

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

## 8. 트러블슈팅

### 이슈 1: kube-proxy Service 라우팅 불가

**증상**: ClusterIP Service로 통신 불가, IPVS 규칙 없음

**원인**: kube-proxy ConfigMap이 구 VIP(10.10.120.229)를 참조

**해결**:

```bash
# kube-proxy ConfigMap 수정
kubectl edit configmap kube-proxy -n kube-system
# server: https://10.10.120.229:6443
# → server: https://10.10.120.220:6443 로 변경

# kube-proxy 재시작
kubectl rollout restart daemonset kube-proxy -n kube-system

# IPVS 규칙 확인
ipvsadm -ln
```

---

### 이슈 2: bitnami 이미지 접근 불가

**증상**: `docker.io/bitnami` 이미지 pull 실패

**원인**: bitnami 이미지 정책 변경으로 docker.io에서 삭제/이전

**해결**: 아래 대체 이미지 사용

| 원래 이미지 | 대체 이미지 |
|-----------|-----------|
| bitnami/postgresql | postgres:16-alpine |
| bitnami/thanos | quay.io/thanos/thanos:v0.35.1 |

---

### 이슈 3: Grafana init-chown-data 실패

**증상**: Grafana Pod Init 단계에서 권한 오류로 재시작 반복

**원인**: PVC 마운트 경로의 파일 권한 문제

**해결** (`helm/values/grafana.yaml`):

```yaml
initChownData:
  enabled: false
```

---

### 이슈 4: Thanos sidecar 이미지 형식 오류

**증상**: kube-prometheus-stack 배포 시 Thanos sidecar 이미지 파싱 오류

**원인**: kube-prometheus-stack chart는 단일 문자열 이미지 형식 요구

**해결** (`helm/values/prometheus.yaml`):

```yaml
# 잘못된 형식
thanosImage:
  registry: quay.io
  repository: thanos/thanos
  tag: v0.35.1

# 올바른 형식
thanosImage: "quay.io/thanos/thanos:v0.35.1"
```

---

### 이슈 5: ERR_TOO_MANY_REDIRECTS (Grafana)

**증상**: nginx-ingress 설치 후 Grafana 접근 시 무한 리다이렉트

**원인**: `grafana.ini.server.root_url`에 서브패스 설정이 리다이렉트 루프 유발

**해결** (`helm/values/grafana.yaml`):

```yaml
# 제거
grafana.ini:
  server:
    root_url: "%(protocol)s://%(domain)s:%(http_port)s/grafana/"
    serve_from_sub_path: true

# 변경 후 (서브패스 없이)
grafana.ini:
  server:
    domain: ""
```

---

### 공통 디버깅 명령어

```bash
# Pod 로그 확인
kubectl logs -n monitoring <pod-name> --previous

# Pod 이벤트 확인
kubectl describe pod -n monitoring <pod-name>

# 전체 이벤트 확인
kubectl get events -n monitoring --sort-by='.lastTimestamp'

# Node 리소스 확인
kubectl top nodes
kubectl top pods -n monitoring
```

---

## 9. 보안 원칙

이 클러스터는 아래 보안 원칙을 적용하여 구성되었습니다.

| 원칙 | 내용 |
|------|------|
| 시크릿 관리 | 하드코딩 금지, kubectl Secret + 환경변수로 주입 |
| RBAC | 최소 권한 원칙, `cluster-admin` 바인딩 없음 |
| 컨테이너 보안 | `privileged: false`, `runAsRoot` 없음 |
| 네트워크 격리 | `hostNetwork: true`는 nginx-ingress에만 한정 |
| 이미지 태그 | `latest` 금지, 명시적 버전 태그 필수 |
| TLS | 외부 노출 엔드포인트는 TLS 적용 권장 (현재 HTTP, 추후 cert-manager 도입 예정) |

---

## 10. 부록 — 레포 구조

```
.
├── CLAUDE.md                         # 프로젝트 지침
├── configs/
│   ├── haproxy/haproxy.cfg           # HAProxy 설정
│   ├── keepalived/
│   │   ├── keepalived-proxy1.conf    # proxy1 VRRP 설정
│   │   └── keepalived-proxy2.conf    # proxy2 VRRP 설정
│   └── kubeadm/kubeadm-init.yaml     # kubeadm 초기화 설정
├── docs/
│   ├── architecture.md               # 아키텍처 상세
│   ├── manual.md                     # 본 문서
│   └── progress.md                   # 작업 진행 상황
├── helm/values/
│   ├── prometheus.yaml               # kube-prometheus-stack values
│   ├── thanos.yaml                   # Thanos values
│   ├── grafana.yaml                  # Grafana values
│   ├── alertmanager.yaml             # Alertmanager values
│   ├── postgresql.yaml               # PostgreSQL HA values
│   ├── minio.yaml                    # MinIO values
│   ├── snmp-exporter.yaml            # SNMP Exporter values
│   └── nginx-ingress.yaml            # nginx-ingress values
├── k8s/
│   └── services/grafana-ingress.yaml # Grafana Ingress 리소스
└── scripts/
    ├── create-secrets.sh             # Kubernetes Secret 생성
    ├── deploy-monitoring.sh          # 모니터링 스택 Helm 배포
    └── k8s-install/
        ├── 00-env.sh                 # 공통 환경변수 정의
        ├── 01-common.sh              # 전 노드 공통 설치
        ├── 02-haproxy-keepalived.sh  # proxy 노드 LB 설정
        ├── 03-master1-init.sh        # master1 클러스터 초기화
        ├── 04-master-join.sh         # master2/3 control-plane 조인
        ├── 05-worker-join.sh         # proxy worker 노드 조인
        ├── 06-calico.sh              # Calico CNI 설치
        ├── 07-label-taint.sh         # 노드 레이블 / 테인트 설정
        └── 08-post-install.sh        # 사후 설치 (namespace, helm)
```

---

## PDF 변환 방법

본 문서는 Markdown 형식으로 작성되었습니다. 아래 방법으로 PDF로 변환할 수 있습니다.

### 방법 1: pandoc + LaTeX (고품질)

```bash
# Ubuntu
sudo apt-get install pandoc texlive-xetex texlive-fonts-recommended

pandoc docs/manual.md \
  -o docs/manual.pdf \
  --pdf-engine=xelatex \
  -V mainfont="NanumGothic" \
  -V geometry:margin=2cm \
  --toc
```

### 방법 2: 브라우저 인쇄 (간편)

1. VS Code → Markdown Preview Enhanced 확장 설치
2. `docs/manual.md` 열기 → 미리보기 실행
3. 미리보기 우클릭 → "Print to PDF"

### 방법 3: GitHub

GitHub에 push 후 브라우저에서 `docs/manual.md` 열기 → 브라우저 인쇄(Ctrl+P) → PDF 저장

---

*본 매뉴얼은 구축 완료 기준(2026-04-07) 시점의 내용을 담고 있습니다.*
