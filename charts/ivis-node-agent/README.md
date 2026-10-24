# ivis-node-agent

`ivis-prove-agent`의 노드 관측 에이전트 설치용 자기완결형 Helm 차트다.
기본 모드는 노드별 **단일 DaemonSet / 단일 Agent 컨테이너**다.
Hubble tap/probe, ivis-server, Collector, Kafka, DB는 설치하지 않는다.
소스 checkout, Go 빌드, 외부 renderer/plugin 없이 이 디렉터리만으로 렌더링한다.

## 기본 설정과 전송 경로

| 항목 | 현재 기본값 |
|---|---|
| Chart version / appVersion | `0.5.1` / `0.5.1` — 가져온 원본 metadata 유지 |
| 실제 기본 Agent 이미지 | `belltigerlee/ivis-prove-agent:0.5.3` |
| 실행 모드 | `agent.mode: builtin` |
| 활성 모듈 | process + CPU counts + syscall counts |
| process snapshot | `true` |
| OTLP | `http://collector:4318`, HTTP JSON (`use_protobuf: false`) |
| 집계 폭 / 전송 주기 | `100ms` / `500ms` — 도착 시간 SLA 아님 |
| 네임스페이스 | Helm `--namespace` / Argo destination namespace |
| 배치 대상 | 기본 Linux nodeSelector, 추가 scheduling/admission 조건 적용 |

CPU/syscall은 OTLP Metrics, process lifecycle/snapshot은 OTLP Logs다.
같은 `agent.otlp.endpoint`의 `/v1/metrics`, `/v1/logs`를 사용한다.
Agent가 Kafka로 직접 전송하지 않는다. Collector에서 두 signal의 receiver/pipeline을
별도로 준비하고 downstream Kafka 인코딩과 소비자를 맞춘다. Agent의
`use_protobuf`는 Collector/Kafka 설정을 자동 변경하지 않는다.

**이미지 공개 여부·pull·실제 실행 호환성은 이 차트의 로컬 검증으로 확인되지 않는다.**
Agent 이미지는 최상위 `image` 한 곳에서 설정한다:

```yaml
image:
  repository: belltigerlee/ivis-prove-agent
  tag: "0.5.3"
  pullPolicy: Always
```

실제 기본 이미지는 `repository:tag`인 `belltigerlee/ivis-prove-agent:0.5.3`이다.
선택적으로 `image.digest`를 지정하면 tag 대신 `repository@digest`를 사용한다.
기존 `agent.image`는 제거했으며 사용하면 schema 검증에서 거부한다.
기존 override의 `agent.image.repository/tag/digest`를 최상위 `image`로 옮긴다.
Chart version/appVersion은 이미지 선택을 대신하지 않는다.

builtin에서는 이것이 유일한 컨테이너 이미지다. external 호환 모드에서도 Agent는
같은 `image`를 사용하지만 모듈은 별도 repository를 사용한다. `image.tag`는 모듈의
기본 tag로도 사용되고 `image.pullPolicy`는 모든 컨테이너에 적용된다.
`image.repository`와 `image.digest`는 모듈에 상속되지 않는다.

## 설치 전제

- Kubernetes `>=1.30.0-0` (Chart.yaml 제약). 실제 커널/BPF 호환성은 별도다.
- 설치할 namespace와 OTLP Collector는 미리 준비한다. 차트는 Namespace/PVC/Secret을 생성하지 않는다.
- 활성 Agent는 hostPID, root, BPF 관련 capabilities, read-only host proc/cgroup/BTF/CRI
  socket 접근을 사용한다. syscall 활성화 시 read-only tracefs도 사용한다.
  Pod 보안 정책이 이 명세를 허용하는지 운영자가 확인한다. 차트가 정책을 완화하지 않는다.
- CRI socket 기본값은 `/run/containerd/containerd.sock`이다. 경로와 소켓 GID에 맞춰
  `runtimeSocket`, `agent.runAsGroup`을 지정한다. 호스트 권한을 변경하지 않는다.
- 현재 syscall 기능은 native x86-64의 `openat`, `openat2`, `connect`, `mmap` exit만 센다.
  기본 Linux selector만으로 이미지의 모든 아키텍처 지원을 의미하지 않는다.
  필요하면 검증된 `nodeSelector.kubernetes.io/arch: amd64`를 추가한다.
- 관측 대상은 배포 namespace에 한정되지 않는다. dedicated ClusterRole은 Pods/owner/Node
  조회와 builtin cluster UID 조회용 `kube-system` namespace get을 허용한다.

## Helm 설치

저장소 루트 기준, 환경에 맞춘 values를 별도 파일로 준비한다.
[`examples/ivis-node-agent/values.yaml`](../../examples/ivis-node-agent/values.yaml)은
복사 후 endpoint와 이미지 등을 수정하는 출발점이다.

```sh
helm lint charts/ivis-node-agent --strict
helm template ivis-node-agent charts/ivis-node-agent \
  --namespace ivis-observer -f examples/ivis-node-agent/values.yaml
# 명시적으로 선택한 kubeconfig/context와 미리 만든 namespace에 설치:
helm upgrade --install ivis-node-agent charts/ivis-node-agent \
  --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" \
  --namespace ivis-observer -f examples/ivis-node-agent/values.yaml
```

`collector.example.invalid` 예시 endpoint는 의도적으로 실제 목적지가 아니다.
명령 실행 전에 반드시 실제 Collector 주소로 바꾼다.

리소스 이름은 release 이름이 아니라 `values.name`에서 결정한다.
기존 설치 이름/selector 호환성을 유지하기 위한 동작이다. 같은 namespace에 여러
인스턴스를 설치한다면 `name`도 서로 다르게 지정해야 한다. 동일 노드 중복 관측은
운영자가 피해야 한다. 이 차트는 기존 설치를 자동 삭제/이전하지 않는다.

## Argo CD

Git repository source에서 다음 필드를 설정한다:

| 필드 | 값 |
|---|---|
| `repoURL` | 이 `ivis-k8s` Git 저장소 주소 |
| `targetRevision` | 검증된 Git 태그/커밋 |
| `path` | `charts/ivis-node-agent` |
| `destination.namespace` | 미리 준비한 설치 namespace |
| `helm.valuesObject` 또는 values 파일 | endpoint, 이미지 등 환경별 설정 |

Git 경로 방식에서는 `source.chart`를 사용하지 않고, `source.directory` 강제 설정도 제거한다.
Argo CD는 Helm template을 렌더링한 리소스를 동기화한다. 별도 Helm release 설치와 구분한다.
이 차트는 Application/AppProject 또는 자동 sync/prune 정책을 생성하지 않는다.
나중에 `ivis-server`는 별도 차트/별도 Application으로 연결한다.

## 모듈과 호환 모드

- 현재 원본 설정을 보존하여 process/CPU/syscall을 모두 활성화했다.
- 별도 values/Argo override에서 모듈을 끄려면 각각 `enabled: false`를 명시한다.
  `modules: {}`나 키 생략은 Helm 병합으로 기본값이 유지된다.
- 세 모듈을 모두 끄면 Agent는 idle이다. 전용 RBAC/hostPID/host mount/token/Secret mount를
  렌더링하지 않는다. 기존 RBAC의 실제 삭제는 배포 도구의 prune 정책에 달려 있다.
- process OFF는 lifecycle Logs를 중단하지만 CPU/syscall의 numeric task identity는 유지한다.
- CPU `config.mode`는 `counts` 또는 `timing`이며 builtin 조합을 지원한다.
- builtin은 `agent.delivery.directory: ""`만 허용한다. 영속 spool 또는 crash 복구를 보장하지 않는다.
- `agent.mode: external`은 기존 모듈별 컨테이너와 OTLP Logs 계약을 보존하는 호환 경로다.
  해당 모듈 이미지도 별도로 준비해야 한다. 기본 배포나 Hubble 활성화 옵션이 아니다.
  `modules.<id>.image.tag`가 없으면 모듈 이미지는 공통 `image.tag`를 따른다.
- external의 optional outbox는 Pod별 emptyDir이며 같은 Pod의 컨테이너 재시작에만 유지된다.
- `agent.metadata`, `agent.stdout`, enrichment/retention 설정 일부는 external 전용이다.
  builtin은 현재 템플릿이 생성하는 task/binding Resource/Attributes를 사용한다.
- 인증/TLS는 `security`의 기존 Secret name/key 참조로 설정한다. 비밀값은 values에 넣지 않는다.

## 패키징과 라이선스

```sh
# 출력 디렉터리는 저장소 외부의 사용자 지정 경로를 사용한다.
helm package charts/ivis-node-agent --destination "$PACKAGE_DIR"
```

패키지에는 templates, module descriptors, schema, values, README, LICENSE가 포함된다.
소스 코드·BPF 오브젝트·개발용 실험은 포함하지 않는다. LICENSE는 이 차트에 적용되며
참조 이미지의 라이선스를 변경하지 않는다. 검증·반영 절차는
[`docs/maintenance.md`](../../docs/maintenance.md)를 참고한다.
