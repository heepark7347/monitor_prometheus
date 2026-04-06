# CLAUDE.md

## 프로젝트
온프레미스 VM 5대 HA K8s 클러스터에 Prometheus + Thanos + Grafana + Alertmanager
모니터링 시스템 구축. 장기 메트릭 저장은 Thanos, 시각화는 Grafana, DB는 PostgreSQL.

## 인프라
| 호스트 | IP | 역할 | 주요 파드 |
|--------|----|------|-----------|
| k8s_master1 | 10.10.120.232 | Control plane + Worker | prometheus-0, grafana-0, postgresql-0, alertmanager-0, thanos-store-0, thanos-query-0, node-exporter |
| k8s_master2 | 10.10.120.233 | Control plane + Worker | prometheus-1, grafana-1, postgresql-1, alertmanager-1, thanos-store-1, thanos-query-1, node-exporter |
| k8s_master3 | 10.10.120.234 | Control plane + Worker | thanos-compactor, grafana-2, postgresql-2, alertmanager-2, thanos-store-2, thanos-query-2, node-exporter |
| proxy1 | 10.10.120.230 | Worker | ingress-ctrl, snmp-exporter, thanos-query |
| proxy2 | 10.10.120.231 | Worker | ingress-ctrl, snmp-exporter, thanos-query |

- proxy 호스트 프로세스: HAProxy + keepalived (컨테이너 아님, K8s 외부)
- 전 노드 공통: kubelet + kube-proxy + containerd + CNI (Calico)
- K8s v1.30 / Helm v3 / namespace: `monitoring`

## 레포 구조
```
k8s/{namespaces,deployments,services,rbac}/
helm/values/{prometheus,grafana,alertmanager,thanos,postgresql,snmp-exporter}.yaml
configs/{prometheus/rules,grafana/dashboards}/
docs/{architecture,progress,runbook}.md
scripts/{validate,helm-diff,check-cluster}.sh
```

## 역할 분담 — Claude Code는 코드 작성만, 배포는 인간이 수동 실행
- `kubectl` / `helm` 명령어 직접 실행 **금지** — 실행 명령은 README 또는 scripts/에 명시
- 단, 사용자가 명시적으로 요청 시 한시 허용 가능 (완료 후 즉시 원복)
- 작업 완료 시 `docs/progress.md` 업데이트 필수

## 골든 원칙
- namespace 항상 명시 (default 사용 금지)
- 모든 Pod에 `resources.requests` + `resources.limits` 필수
- helm 옵션은 `helm/values/*.yaml` 파일로만 관리 (`--set` 인라인 금지)
- StatefulSet 사용 시 podAntiAffinity로 master 3대에 분산 배치 명시
- master taint 고려: control plane 워크로드는 toleration 명시
- HAProxy/keepalived는 K8s 외부 프로세스 — manifest 대상 아님
- 불확실한 결정은 추측 금지 → `docs/architecture.md` 참조 또는 확인 요청

## 보안 원칙 (위반 시 코드 작성 중단 후 사유 보고)
- 시크릿·토큰·패스워드 하드코딩 **절대 금지** → 플레이스홀더 `<REPLACE_ME>` 사용
- RBAC: 최소 권한 원칙 적용, `cluster-admin` 바인딩 금지
- 컨테이너 `privileged: true` / `runAsRoot` 금지
- `hostNetwork: true` / `hostPID: true` 금지
- 이미지 태그 `latest` 사용 금지 → 명시적 버전 태그 필수
- TLS 미적용 엔드포인트를 외부에 노출하는 설정 금지

## Git 커밋 원칙 (모든 작업은 커밋으로 기록)
- 구축에 사용된 **모든 명령어·코드·설정 파일**은 커밋 대상 — 구두 설명으로 대체 불가
- 커밋 단위: 기능/설정 1개 = 커밋 1개
- 커밋 메시지 형식: `<type>(<scope>): <한줄 요약>`
  - type: `feat` `fix` `docs` `chore` `security`
  - 예: `feat(thanos): store gateway StatefulSet 분산 배치 설정`
- 명령어는 `scripts/*.sh` 파일로 저장 후 커밋 (일회성 명령도 포함)

## 피드백 루프
에이전트가 같은 실수를 반복하면 → 이 파일 해당 섹션에 규칙 추가 후 커밋
`docs: CLAUDE.md 업데이트 — <이유>`

## 세션 시작 시 읽기 순서
1. `CLAUDE.md` → 2. `docs/progress.md` → 3. `docs/architecture.md`
