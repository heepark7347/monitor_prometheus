# Progress

## 상태 범례
- ✅ 완료
- 🔄 진행 중
- ⏳ 대기

---

## Phase 1 — Kubernetes 클러스터 설치

| # | 작업 | 상태 | 커밋 | 비고 |
|---|------|------|------|------|
| 1.1 | 설치 스크립트 작성 | ✅ | feat(k8s): 클러스터 설치 스크립트 | scripts/k8s-install/ |
| 1.2 | HAProxy/keepalived 설정 | ✅ | feat(k8s): 클러스터 설치 스크립트 | configs/haproxy/, configs/keepalived/ |
| 1.3 | kubeadm init 설정 | ✅ | feat(k8s): 클러스터 설치 스크립트 | configs/kubeadm/kubeadm-init.yaml |
| 1.4 | 전 노드 공통 설치 실행 | ⏳ | — | 01-common.sh 수동 실행 필요 |
| 1.5 | HAProxy/keepalived 배포 | ⏳ | — | 02-haproxy-keepalived.sh 수동 실행 |
| 1.6 | master1 초기화 | ⏳ | — | 03-master1-init.sh 수동 실행 |
| 1.7 | Calico CNI 설치 | ⏳ | — | 06-calico.sh 수동 실행 |
| 1.8 | master2/3 CP 조인 | ⏳ | — | 04-master-join.sh 수동 실행 |
| 1.9 | proxy1/2 워커 조인 | ⏳ | — | 05-worker-join.sh 수동 실행 |
| 1.10 | 노드 레이블/테인트 | ⏳ | — | 07-label-taint.sh 수동 실행 |
| 1.11 | monitoring namespace | ⏳ | — | 08-post-install.sh 수동 실행 |

## Phase 2 — 모니터링 스택 배포

| # | 작업 | 상태 | 커밋 | 비고 |
|---|------|------|------|------|
| 2.1 | Prometheus HA values | ⏳ | — | helm/values/prometheus.yaml |
| 2.2 | Thanos values | ⏳ | — | helm/values/thanos.yaml |
| 2.3 | Grafana values | ⏳ | — | helm/values/grafana.yaml |
| 2.4 | Alertmanager values | ⏳ | — | helm/values/alertmanager.yaml |
| 2.5 | PostgreSQL values | ⏳ | — | helm/values/postgresql.yaml |
| 2.6 | SNMP Exporter values | ⏳ | — | helm/values/snmp-exporter.yaml |

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
