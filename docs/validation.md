# node-agent 차트 가져오기 검증

## 현재 설정: Agent image 블록 통합

- Agent 이미지 설정은 최상위 `image.repository/tag/pullPolicy`와 선택적 `image.digest`만 사용한다.
- `agent.image`를 values/schema/templates에서 제거했다. 예전 override는 schema 오류로 거부하며
  README에 최상위 image로 옮기는 방법을 명시했다.
- builtin/external 모두 Agent 선택 경로를 수정했다. 모듈별 external 이미지 설정은 보존하며
  Agent repository/digest가 별도 모듈에 잘못 상속되지 않는 것도 검사했다.
- 수정 직전과 비교해 builtin/external 기본 렌더의 모든 리소스가 동일하다.
  Agent 이미지는 여전히 `belltigerlee/ivis-prove-agent:0.5.3`이다.
- 실제 binary 지정 **11 tests / 0 skipped**, Helm strict lint, `git diff --check` 통과.
- 아래 버전 단일화/최초 가져오기 절은 이전 단계 기록이다. 현재 설정 계약은 이 절과 README를 따른다.
- 이미지 pull·클러스터 배포·commit/push는 하지 않았다.

## 후속 수정: 이미지 버전 단일화

- 기본 버전을 `image.tag: "0.5.3"`으로 모으고 기본 `agent.image.tag` 중복을 제거했다.
  예시 values와 README도 같은 설정 방식을 따른다. 개별 tag/digest override 지원은 유지한다.
- 기본 builtin 렌더는 수정 전과 리소스 전체가 동일함을 확인했다.
- external 모드에서 개별 override가 없는 모듈도 공통 `0.5.3`을 따른다.
  해당 모듈 이미지의 registry 존재/호환성을 확인했다는 뜻은 아니다.
- 공통 tag 변경과 개별 Agent/모듈 override 회귀 검사를 추가했고, 실제 binary 지정 시
  **11 tests / 0 skipped**, Helm strict lint, `git diff --check`가 모두 통과했다.
- 아래 기록과 `node-agent-import.json`의 해시는 **최초 가져오기 시점**의 증거다.
  이 후속 설정/README 변경 이후의 파일 해시나 전체 source parity를 나타내지 않는다.
- 소스 저장소 수정, 이미지 publication, Git commit/push, 클러스터 배포는 하지 않았다.

## 산출물과 변경 경계

- 배포 경로: `charts/ivis-node-agent`.
- 원본: `ivis-prove-agent/k8s/ivis-node-agent`의 현재 작업 트리.
- 원본 HEAD: `9d0aa8d0fc3cec7a6f47450e0d3232ca685ceefb`.
  원본에는 미커밋 변경이 있으므로 HEAD만으로 이번 차트를 재생성할 수는 없다.
- 파일별 원본/배포 SHA-256: [`node-agent-import.json`](node-agent-import.json).
- 원본 실행 templates/schema/Chart metadata를 유지했다. values 및 syscall descriptor는
  주석만 정정했고 YAML 설정값은 보존했다. 배포용 README는 실제 설정에 맞게 작성했다.
- 기존 `ivis-k8s/LICENSE`는 변경하지 않았으며 패키지에도 같은 Apache-2.0 사본을 포함했다.
- Hubble/서버/Collector/Kafka 설치물, Application/AppProject, CI publication은 추가하지 않았다.
- 원본 chart의 전체 파일 해시와 Git status가 작업 전후 동일함을 확인했다.

## 실제 수행 결과

사용 도구: Helm `v3.21.3+g1ad6e68`, Python 3 + PyYAML.

| 검사 | 결과 |
|---|---|
| `helm lint charts/ivis-node-agent --strict` | PASS, 1 chart / 0 failed; icon 권고 INFO만 있음 |
| `python3 -m unittest discover -s tests -p 'test_*.py' -v` (아래 binary 지정) | PASS, 10 tests / 0 skipped |
| 다른 작업 디렉터리에서 절대 tests 경로로 재실행 | PASS, 10 tests / 0 skipped |
| 원본/배포 렌더 동등성 | PASS: default, idle, external, protobuf, timing |
| 독립 chart 복사 및 `.tgz` package 렌더 동등성 | PASS |
| package LICENSE 포함·동등성 | PASS |
| process/CPU/syscall 활성 조합 | PASS: 8개 전체 조합 |
| namespace·RBAC subject·name 정합성 | PASS: 두 namespace 및 custom name |
| builtin JSON / HTTP protobuf / gRPC protobuf, CPU timing | PASS |
| 잘못된 인코딩·CPU 모드·builtin disk outbox 설정 거부 | PASS |
| 실제 Agent의 생성 설정 파싱 | PASS: 12개 profile |
| all-off 실제 idle 시작 → SIGTERM 종료 | PASS: exit 0, OTLP requests/source_samples 0 |
| 기존 root LICENSE·원본 chart 파일·원본 Git status 보존 | PASS |
| `git diff --check` 및 untracked 파일별 whitespace 검사 | PASS |

실제 binary는 소스 저장소에서 다음 명령으로 빌드했다. 애플리케이션 소스는 수정하지 않았다.

```sh
GOMAXPROCS=2 go build -p 1 \
  -o /home/work8/.hermes/cache/scratch/ivis-k8s-validation/ivis-node-agent \
  ./cmd/ivis-node-agent
```

배포 저장소에서:

```sh
IVIS_AGENT_BINARY=/home/work8/.hermes/cache/scratch/ivis-k8s-validation/ivis-node-agent \
  python3 -m unittest discover -s tests -p 'test_*.py' -v
```

binary는 임시 검증 산출물이므로 나중에 없어질 수 있다. 재검증 시 호환 binary를 다시 빌드하거나
별도로 지정한다. 기본 Helm 검사에는 소스 저장소/binary가 필요 없으며 runtime 두 검사는
binary를 지정하지 않으면 명시적으로 skip된다. idle 실행은 충돌 방지를 위해 생성 설정의
listen 주소만 `127.0.0.1:0`으로 바꿨고 BPF attach/클러스터 접속 없이 수행했다.

## 아직 검증하지 않은 것

- 기본 이미지 `belltigerlee/ivis-prove-agent:0.5.3`의 registry 공개 여부, pull 및 실제 실행.
- 대상 클러스터 admission/BPF/CRI 권한, Collector Logs/Metrics 수신, Kafka/서버 처리.
- Argo CD 등록/sync, live 설치·업그레이드·삭제.
- 전체 Go 회귀 테스트 (이번 작업은 배포 chart 복사/문서/독립 검사만 변경).

Git commit/push, 이미지 build/push, 클러스터 리소스 변경은 수행하지 않았다.
위 Go binary 빌드는 로컬 설정 검증용이며 컨테이너 이미지 build가 아니다.
