# Architecture

## 클러스터 개요

온프레미스 VM 5대로 구성된 HA Kubernetes v1.30 클러스터.
모니터링 스택(Prometheus + Thanos + Grafana + Alertmanager)을 `monitoring` namespace 에 배포.

## 네트워크 구성

```
외부 트래픽
     │
     ▼
keepalived VIP: 10.10.120.229
     │
     ├─── proxy1 (10.10.120.230) ── HAProxy → API 6443
     └─── proxy2 (10.10.120.231) ── HAProxy → API 6443 (BACKUP)
                                          │
                          ┌───────────────┼───────────────┐
                          ▼               ▼               ▼
                    master1:6443    master2:6443    master3:6443
                 (10.10.120.232) (10.10.120.233) (10.10.120.234)
```

| 구성요소 | 값 |
|----------|----|
| Control Plane VIP | 10.10.120.229 |
| API 서버 포트 | 6443 |
| Pod CIDR | 192.168.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| CNI | Calico v3.28.0 (VXLAN CrossSubnet) |
| kube-proxy 모드 | ipvs |
| CRI | containerd v1.7.22 |

## 노드 역할

| 호스트 | IP | 역할 | taint | zone |
|--------|----|----|-------|------|
| k8s-master1 | 10.10.120.232 | Control Plane + Worker | control-plane:NoSchedule | zone-a |
| k8s-master2 | 10.10.120.233 | Control Plane + Worker | control-plane:NoSchedule | zone-b |
| k8s-master3 | 10.10.120.234 | Control Plane + Worker | control-plane:NoSchedule | zone-c |
| proxy1 | 10.10.120.230 | Worker (ingress/snmp) | — | zone-proxy-a |
| proxy2 | 10.10.120.231 | Worker (ingress/snmp) | — | zone-proxy-b |

## HA 구조

### Control Plane HA
- kubeadm stacked etcd: etcd 가 각 master 에 내장
- HAProxy(proxy1/2) → VIP(10.10.120.229) → master1/2/3:6443 라운드로빈
- keepalived VRRP: proxy1 MASTER(priority 101), proxy2 BACKUP(priority 100)

### 워크로드 분산
- StatefulSet 은 `podAntiAffinity` + `topology.kubernetes.io/zone` 으로 master1/2/3 분산
- master taint 는 유지, 워크로드에 `toleration` 명시

## 스케줄링 정책

```yaml
# master 노드 워크로드 공통 toleration
tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"

# StatefulSet 분산 배치 공통 podAntiAffinity
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: <app-name>
        topologyKey: "topology.kubernetes.io/zone"
```

## 외부 프로세스 (K8s manifest 대상 아님)

| 호스트 | 프로세스 | 설정 파일 |
|--------|----------|-----------|
| proxy1 | HAProxy | configs/haproxy/haproxy.cfg |
| proxy1 | keepalived | configs/keepalived/keepalived-proxy1.conf |
| proxy2 | HAProxy | configs/haproxy/haproxy.cfg |
| proxy2 | keepalived | configs/keepalived/keepalived-proxy2.conf |
