# ivis-k8s

IVIS 구성 요소를 독립적으로 설치하는 Helm 차트 저장소다.
애플리케이션 소스나 개발용 실험 환경은 포함하지 않는다.

## 차트

| 경로 | 구성 요소 | 상태 |
|---|---|---|
| [`charts/ivis-node-agent`](charts/ivis-node-agent) | `ivis-prove-agent`의 노드 관측 에이전트 | 포함 |

Hubble tap/probe, Collector, Kafka, 데이터베이스와 서버는 이 차트가 설치하지 않는다.
`ivis-server` 차트는 추후 `charts/ivis-server/`에 추가한다. 아직 구현되지 않은
서버 차트나 설치용 placeholder는 만들지 않는다.

## 저장소 확장 규칙

- `charts/<chart-name>/`: 독립적인 `Chart.yaml`, `values.yaml`, schema, templates,
  README와 LICENSE를 가진 자기완결형 차트. 다른 차트나 private 소스 경로를 참조하지 않는다.
- `examples/<chart-name>/`: 비밀정보 없는 환경별 values 예시.
- `tests/`: 공통 차트 패키징 검사 및 구성 요소별 회귀 검사.
- `docs/`: 유지보수·검증 기록.
- 차트별 버전, 이미지 버전, Argo CD Application을 독립적으로 관리한다.
  루트 umbrella chart나 서버/에이전트 간 강제 dependency는 두지 않는다.
- 새 차트는 `charts/*/Chart.yaml`로 공통 검사에 자동 포함된다.

## 설치

에이전트의 설정, 권한, 이미지 선택과 설치 명령은
[`charts/ivis-node-agent/README.md`](charts/ivis-node-agent/README.md)를 따른다.

Argo CD에서 Git 소스를 사용한다면 이 저장소와 `path: charts/ivis-node-agent`를
지정한다. 운영 환경은 검증된 Git 태그/커밋을 `targetRevision`으로 고정한다.
Git-hosted chart에는 `source.chart`나 `source.directory`를 함께 지정하지 않는다.
차트 버전만 바꿔서는 Git 소스 revision이 변경되지 않는다.
Application/AppProject 생성이나 sync는 이 저장소의 로컬 검증에 포함하지 않는다.

## 로컬 검증

Helm 3와 Python 3 + PyYAML이 필요하다. 저장소 루트에서:

```sh
helm lint charts/ivis-node-agent --strict
helm template ivis-node-agent charts/ivis-node-agent --namespace ivis-observer
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

의존성 설치가 필요한 경우 격리된 Python 환경에서 `tests/requirements.txt`를 사용한다.
실행 시 임시 파일은 `TMPDIR` 또는 사용자 cache 아래에만 생성한다.
실제 검증 범위와 소스 반영 절차는 [`docs/maintenance.md`](docs/maintenance.md)를 참고한다.

## 라이선스

이 저장소의 차트와 문서는 기존 [`LICENSE`](LICENSE)의 Apache-2.0을 따른다.
각 차트 패키지에도 같은 LICENSE를 포함한다. 참조하는 컨테이너 이미지,
애플리케이션 및 제3자 구성 요소의 라이선스는 별도이며 이 차트로 변경하지 않는다.
