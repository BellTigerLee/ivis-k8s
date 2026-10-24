# 차트 유지보수

## 독립 차트 추가

`charts/<name>/` 아래에 자기완결형 차트를 추가한다. 각 차트는 고유한 이름,
독립 version/appVersion, values/schema, templates, README, LICENSE를 가진다.
새 `ivis-server` 차트를 추가해도 node-agent의 dependency, 이미지, 기본 설정 또는
배포 시점을 함께 바꾸지 않는다. 루트 Chart.yaml/umbrella dependency는 두지 않는다.
차트 간 필수 연동은 endpoint와 명시적인 호환성 문서로 정의한다.

공통 테스트는 모든 `charts/*/Chart.yaml`을 찾아 lint, standalone/package 렌더 동등성,
패키지 LICENSE 포함 여부와 중복 리소스 identity를 검사한다.
구성 요소별 테스트는 별도로 추가한다. 새 차트도 기본값의 오프라인 렌더가 가능해야 한다.

## node-agent 소스 반영

배포 chart의 원본은 `ivis-prove-agent` 소스 저장소의 `k8s/ivis-node-agent/`다.
이 저장소의 설치/테스트에는 그 소스 저장소가 필요하지 않다.

1. 원본 작업 트리와 변경 사항을 읽고 배포 가능한 chart 파일만 선택한다.
2. templates/schema/descriptors를 비교하고 배포 저장소의 사용자 설정을 보존한다.
   소스의 README에는 역사적 설명이 섞일 수 있으므로 실제 코드/values와 대조한다.
3. 이미지 공개 여부와 지원 프로토콜은 별도로 검증한다. 배포 차트의 Agent 이미지는
   최상위 image.repository/tag/pullPolicy 및 선택적 image.digest로 설정한다.
   agent.image는 지원하지 않는다. Chart.yaml metadata는 이미지 선택이 아니다.
4. 원본과 배포 차트의 렌더를 동일 release/namespace 및 동등한 설정으로 비교한다.
   원본이 agent.image를 사용하면 배포 차트의 최상위 image로 변환한다.
5. 모든 차트 검사와 node-agent 기능 조합/idle/인코딩 검사를 수행한다.
6. 변경 의미에 맞춰 차트 버전을 결정하고 검증한 Git revision을 배포에 사용한다.
   버전 변경·image build/push·Git commit/push·Argo sync를 자동으로 묶지 않는다.

원본 개발/실험 manifest, Secret, 클러스터 endpoint, Go/BPF 소스는 복사하지 않는다.
Hubble tap/probe는 현재 배포 범위 밖이다.

## 검증 명령

저장소 루트에서 `python3 -m unittest discover -s tests -p 'test_*.py' -v`.
Helm과 `tests/requirements.txt`의 Python 의존성이 필요하다.
다른 cwd에서 실행해도 테스트는 파일 위치 기준으로 chart를 찾는다.

선택적으로 검증할 Agent 바이너리가 있으면 `IVIS_AGENT_BINARY`에 절대 경로를 설정한다.
테스트는 생성된 builtin/external 설정에 `--check-config`를 호출하고,
all-off builtin은 실제 idle 실행을 시작해 SIGTERM 종료를 확인한다.
이 바이너리가 없으면 런타임 검사는 명시적으로 skipped이며 Helm 검사는 수행한다.
테스트는 클러스터에 접속하거나 BPF를 attach하지 않는다.

로컬 렌더/설정 파싱은 이미지 pull, 실제 BPF 동작, Collector 수신, Kafka/서버 전달,
Argo CD sync 또는 운영 namespace의 admission을 증명하지 않는다.
