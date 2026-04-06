# Progress

## 상태 범례
- ✅ 완료
- 🔄 진행 중
- ⏳ 대기

---

## Phase 1 — Kubernetes 클러스터 설치

| # | 작업 | 상태 | 커밋 | 비고 |
|---|------|------|------|------|
| 1.0 | SSH 키 인증 설정 | ✅ | chore(infra): SSH 키 배포 및 config 설정 | ~/.ssh/k8s_cluster (ed25519) |
| 1.1 | 설치 스크립트 작성 | ✅ | feat(k8s): 클러스터 설치 스크립트 | scripts/k8s-install/ |
| 1.2 | HAProxy/keepalived 설정 | ✅ | feat(k8s): 클러스터 설치 스크립트 | configs/haproxy/, configs/keepalived/ |
| 1.3 | kubeadm init 설정 | ✅ | feat(k8s): 클러스터 설치 스크립트 | configs/kubeadm/kubeadm-init.yaml |
| 1.4 | 전 노드 공통 설치 실행 | ✅ | — | 01-common.sh 5대 실행 완료 (2026-04-03) |
| 1.5 | HAProxy/keepalived 배포 | ✅ | — | VIP 10.10.120.220 활성화 확인 (enX0) |
| 1.6 | master1 초기화 | ✅ | — | kubeadm init 성공 (2026-04-03) |
| 1.7 | Calico CNI 설치 | ✅ | — | v3.28.0 Tigera Operator 방식 |
| 1.8 | master2/3 CP 조인 | ✅ | — | control-plane 노드 3대 Ready |
| 1.9 | proxy1/2 워커 조인 | ✅ | — | worker 노드 2대 Ready |
| 1.10 | 노드 레이블/테인트 | ✅ | — | zone 레이블 + node-type 레이블 적용 |
| 1.11 | monitoring namespace | ✅ | — | namespace/monitoring 생성 완료 |
| 1.12 | Helm v3 설치 | ✅ | — | helm v3.20.1 (master1 /usr/local/bin) |
| 1.13 | Control Plane VIP 변경 적용 | ✅ | fix(infra): VIP 변경 | API 서버 인증서 재발급 + kubelet.conf 전 노드 업데이트 |

### 클러스터 최종 상태 (2026-04-03)

```
NAME          STATUS   ROLES                  VERSION   INTERNAL-IP
k8s-master1   Ready    control-plane,worker   v1.30.0   10.10.120.232
k8s-master2   Ready    control-plane,worker   v1.30.0   10.10.120.233
k8s-master3   Ready    control-plane,worker   v1.30.0   10.10.120.234
proxy1        Ready    worker                 v1.30.0   10.10.120.230
proxy2        Ready    worker                 v1.30.0   10.10.120.231
```

### 인프라 설정 변경사항

| 항목 | 원래 값 | 실제 값 | 비고 |
|------|---------|---------|------|
| NIC 이름 | ens3 | enX0 | proxy 노드 실제 NIC |
| keepalived auth_pass | `<REPLACE_ME>` | 설정 완료 | configs/keepalived/*.conf 업데이트 |

## Phase 2 — 모니터링 스택 배포

| # | 작업 | 상태 | 커밋 | 비고 |
|---|------|------|------|------|
| 2.1 | Prometheus HA values | ✅ | feat(prometheus): kube-prometheus-stack values | helm/values/prometheus.yaml |
| 2.2 | Thanos values | ✅ | feat(thanos): store/query/compactor values | helm/values/thanos.yaml |
| 2.3 | Grafana values | ✅ | feat(grafana): HA StatefulSet values | helm/values/grafana.yaml |
| 2.4 | Alertmanager values | ✅ | feat(alertmanager): 3-replica HA values | helm/values/alertmanager.yaml |
| 2.5 | PostgreSQL values | ✅ | feat(postgresql): HA + pgpool values | helm/values/postgresql.yaml |
| 2.6 | SNMP Exporter values | ✅ | feat(snmp): proxy 노드 배치 values | helm/values/snmp-exporter.yaml |
| 2.7 | Secret 생성 스크립트 | ✅ | feat(security): create-secrets.sh | scripts/create-secrets.sh |
| 2.8 | 배포 스크립트 | ✅ | feat(deploy): deploy-monitoring.sh | scripts/deploy-monitoring.sh |
| 2.9 | local-path-provisioner 설치 | ✅ | — | v0.0.28, default StorageClass |
| 2.10 | Secret 실제 생성 | ✅ | — | grafana-db-secret, postgresql-ha-secret, thanos-objstore-secret, minio-secret |
| 2.11 | MinIO 설치 (Thanos 오브젝트스토리지) | ✅ | feat(monitoring): 배포 완료 | helm/values/minio.yaml, thanos 버킷 생성 |
| 2.12 | kube-proxy 구 VIP 버그 수정 | ✅ | feat(monitoring): 배포 완료 | kube-proxy ConfigMap 10.10.120.229→10.10.120.220, IPVS 동기화 복구 |
| 2.13 | Helm 배포 전체 실행 완료 | ✅ | feat(monitoring): 배포 완료 | 전체 파드 Running 확인 (2026-04-06) |
| 2.14 | nginx-ingress 설치 | ✅ | feat(ingress): nginx-ingress DaemonSet | proxy1/2 hostNetwork DaemonSet |
| 2.15 | Grafana 외부 접근 설정 | ✅ | feat(ingress): Grafana Ingress 배포 | http://<공인IP>/ → Grafana, root_url 수정 |

### 모니터링 스택 최종 상태 (2026-04-06)

| 컴포넌트 | 파드 | 노드 배치 |
|----------|------|-----------|
| Prometheus | 0,1 Running (3/3) | master2, master1 |
| Alertmanager | 0,1,2 Running | master3, master2, master1 |
| Grafana | 0,1,2 Running | master3, master2, master1 |
| Thanos StoreGateway | 0,1,2 Running | master3, master2, master1 |
| Thanos Query | 3개 Running | master2, master1, master3 |
| Thanos QueryFrontend | 1개 Running | master1 |
| Thanos Compactor | 1개 Running | master3 |
| MinIO | 4개 Running | master3, master2, master1, master3 |
| PostgreSQL | 1개 Running | master1 |
| SNMP Exporter | 2개 Running | proxy2, proxy1 |
| node-exporter | 5개 Running (DaemonSet) | 전 노드 |

### 설치 중 발견된 주요 이슈

| 이슈 | 원인 | 해결 |
|------|------|------|
| kube-proxy Service 라우팅 불능 | kube-proxy ConfigMap이 구 VIP(10.10.120.229) 참조 | config.conf + kubeconfig.conf 수정, 재시작 |
| bitnami 이미지 접근 불가 | docker.io/bitnami 이미지 삭제/이전 | postgres:16-alpine, quay.io/thanos 직접 사용 |
| Grafana init-chown-data 실패 | PVC 권한 문제 | initChownData.enabled: false |
| Thanos sidecar 이미지 형식 | kube-prometheus-stack은 단일 문자열 요구 | "quay.io/thanos/thanos:v0.35.1" 로 수정 |
| objectStorageConfig 키 이름 | secret → existingSecret | values 수정 |

## 실행 순서 요약

```
# 전 노드 (5대)
sudo bash scripts/k8s-install/01-common.sh

# proxy1
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy1

# proxy2
sudo bash scripts/k8s-install/02-haproxy-keepalived.sh proxy2

# master1
sudo bash scripts/k8s-install/03-master1-init.sh

# master1 (CNI 먼저 설치)
bash scripts/k8s-install/06-calico.sh

# master2
export CONTROL_PLANE_JOIN_CMD="<03 출력값>"
sudo -E bash scripts/k8s-install/04-master-join.sh

# master3
export CONTROL_PLANE_JOIN_CMD="<03 출력값>"
sudo -E bash scripts/k8s-install/04-master-join.sh

# proxy1
export WORKER_JOIN_CMD="<kubeadm token create --print-join-command 출력값>"
sudo -E bash scripts/k8s-install/05-worker-join.sh

# proxy2
export WORKER_JOIN_CMD="<kubeadm token create --print-join-command 출력값>"
sudo -E bash scripts/k8s-install/05-worker-join.sh

# master1
bash scripts/k8s-install/07-label-taint.sh
bash scripts/k8s-install/08-post-install.sh
```
