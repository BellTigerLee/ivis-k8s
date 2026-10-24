# IVIS server 0.4.0 공식 Helm chart 구현

## 사용자 확정과 대상

사용자 요청: `/home/work8/workspace/ivis-k8s` 공식 배포 저장소에 ivis-server Helm chart를 추가한다. ClickHouse/PostgreSQL 서버와 사용자가 만든 user Secret은 이미 존재한다고 가정하여 **그 Secret을 그대로 참조**한다. 필요한 SQL을 Job 한 번으로 준비하고 server Deployment를 실행하면 된다. Job/Deployment 시작 순서를 복잡하게 강제할 필요는 없고, 먼저 시작한 서버가 실패하면 SQL 완료 뒤 재시도/사용자 재시작으로 복구할 수 있다.

추가 선택 질문에 사용자가 **‘최근 구현한0.4.0 기준 — worktree의 서버·SQL 계약 사용’**을 명시 선택했다. primary main0.3.11로 구현하지 않는다.

- 유일한 편집 root: `/home/work8/workspace/ivis-k8s`, main, 시작 HEAD `ca84af1dcdec76df3a7696b9c532f425b597f63d`, 부모 확인 시 clean.
- 새 chart: `charts/ivis-server/`. 기존 `charts/ivis-node-agent/`, 그 examples·기본값·이미지·버전·라이선스·render는 보존한다.
- 서버 정본 **read-only**: `/home/work8/.herdr/worktrees/ivis-server/worktree-040-opus55`, feature/ivis-040-opus55. 실제 최신 미커밋0.4.0 source/SQL 계약을 사용한다. source HEAD만으로 배포 후보 bytes를 식별하지 말고 선택한 원본의 hash/provenance를 남긴다.
- primary `/home/work8/workspace/ivis-server`, Agent/monitor repo, 다른 worktree·기존 세션/DB/클러스터/원격GitOps는 변경 금지. 이전성능gate나k8s정리를재개하지않는다.

## 실행 방식·안전

fresh native Codex gpt-6.1-sol/xhigh/YOLO, pane w5:p29, 이름 ivis-server-helm-sol61. 실제 mattpocock1.3.1 ask-matt→implement/tdd, 마지막 짧은 code-review를 읽는다: `/home/work8/.codex/plugins/cache/mattpocock/mattpocock-skills/1.3.1/skills/engineering/`.

이 저장소에는 부모가 확인한 root AGENTS/CLAUDE가 없고 README.md, docs/maintenance.md, tests/test_charts.py가 배포 규칙이다. 기존 문서·테스트 방식을 따른다. 프로젝트 관리 bootstrap/issue/PR/추가 coding·review agent는 만들지 않는다.

**Secret 값/.env/credential 파일/kubeconfig 본문/전체 process env 및 `/home/work8/workspace/environment.md` 읽기·출력 금지.** 기존 Secret은 실제 조회하지 않고 참조 인터페이스만 만든다. 렌더/오류/테스트로그에 credential을 넣지 않는다. node-agent 바이너리·BPF 실행도 하지 않는다.

Git commit/push/tag, image build/push, helm install/upgrade, kubectl apply/delete/patch, Argo sync, 실제 DB 접속/DDL, 기존 DevSpace 변경은 승인되지 않았다. 이번 deliverable은 chart+실행 가능한 schema Job+로컬 검증이다. 작은 ephemeral **로컬** DB smoke는 아래 예산/조건에서만 허용한다.

## 1. 실제0.4.0 의존성부터 확정

정본 source/SQL을 먼저 읽고 소형 설치 inventory를 만든다:
- `src/ivis_server/db_manifest.py`, config/main/execution_generation/postgres_schema.
- `docs/databases/sql/postgres/kumec/{001_kumec_signal,002_access}.sql`, native-current SQL 및 실제 db_manifest.DDL.
- `docs/databases/sql/bootstrap/clickhouse/010_tables.sql`의0.4.0 정의와 `storage_sinks.py`/kumec/signals 실제 table·column 소비.
- `k8s/deploy/{svr-deployment,svr-configmap,svr-rbac}.yaml`의0.4.0 설정과 실제 loader. 이전 README의 native 미지원/no-commit 문장은 역사적 내용이므로 복제하지 않는다. 현재 source는 native OTLP JSON/protobuf 및 committed-offset resume를 지원한다.
- 최신 `docs/tasks/2026-10-24_min-live-r1-report.ko.md`, `docs/databases/verification/2026-10-24-min-live/PARENT-FINAL.ko.md`는 기능/성능 구분 참고다. 실시간 처리량 우위는 미입증이며 chart 생성으로 해결됐다고 하지 않는다.

정상0.4.0 core/native 실행 함수/default seed, KumeC/signals PG 스키마와 CH `ivis_kumec_history`, `ivis_signal_event`, `ivis_signal_sample`을 빠뜨리지 않는다. core가 읽는 원천 DB와 signals가 쓰는 DB를 구분한다. 지원되는 기본값/옵션의 SQL 목록과 upstream 원천 표·Kafka/Collector 전제도 명확히 적는다. 단순히0.3.11 legacy schema-init Job만 옮기지 않는다.

## 2. chart 계약 — 실제 Helm, 자기완결형

Chart.yaml, values.yaml, values.schema.json, templates, README, 기존rootLICENSE와동일한LICENSE, .helmignore, 필요한 files/SQL/runner, examples/ivis-server/를 제공한다. 다른/private repo 파일이 설치 때 필요하면 안 된다. symlink/외부generator/Helm dependency/DB operator/umbrella chart/Application/AppProject는 추가하지 않는다.

- 설치 namespace는 `.Release.Namespace`, 기본 문서/예시는 `ivis-observer`. namespace를 chart가 임의 생성/삭제하지 않는다. Service/SA/RBAC subject와 cluster-scope 이름을 일치시킨다.
- image는 기존 배포 저장소 스타일대로 최상위 repository/tag/pullPolicy와 선택 digest. 후보 default는 `belltigerlee/ivis-server:0.4.0`; 사용자 확정한 source에 대응한다. **해당 최신 worktree를 담은 이미지의 게시/pull/내용은 미검증**이다. 구base0.3.11+source override 검증을0.4.0 이미지 검증으로 둔갑시키지 않는다.
- replica1/Recreate, 기존0.4.0 non-root/readonly-root/seccomp/cap-drop와 probe 실제 경로를 기준으로 한다. PG backend에서 불필요한/state PVC를 새로 추가하지 않는다. 필요한/tmp 등은bounded emptyDir. native inventory에 필요한 최소 read RBAC만, schema Job은 K8s token/Deployment 삭제 권한이 필요 없다.
- 기존 Secret 이름과 key 이름을 values로 받는다. 평문 비밀번호/새 Secret/계정/password rotation/강제 admin 계정 생성은 없다. PG 기존DSN key를 지원하고, 일반 username/password key 사용도 필요하면 작고 안전한 연결 구성으로 지원한다. CH username/password key와 DB/endpoint 설정을 명시한다. 비밀값을Helm문자열로조립하거나argv/로그에노출하지않는다.
- 서버와 Job 모두 같은 사용자가 준비한 credentials를 재사용하는 경로가 작동해야 한다. optional 별도 init Secret이 있더라도 새 owner Secret을 필수로 강요하지 않는다. 사용자에게 **DDL 권한이 필요**함을 설명한다. 단순runtime읽기쓰기만가능한계정이면Job이명확히실패해야하며자동승격하지않는다.
- PG의 base generation은 설치 SQL이 만드는default와 맞춘다. 임의release/namespace 이름으로바꿔없는seed를가정하지않는다.
- signals/KumeC/native 설정과 storage 필드를 실제 source loader로 검증한다. storage 일부 누락으로memory-only에빠져서는안된다. legacy Metrics/CPU/process/compact를 새로 켜지 않는다. Kafka topic과JSON/protobuf adapter 매핑은 명시 values로 설정 가능하게 하고 Agent에비표준wire변경을요구하지않는다.
- 원본의 lab hostname/IP/cluster UID/cluster name은 public default에 복사하지 않는다. generic 예시와 필수 설치 입력을 구분한다. 동일 collector 원천을 읽는 선택자와 consumer/writer identity를 혼동하지 않는다.

## 3. 단순 SQL Job + Deployment

사용자가 순서 강제를 원하지 않는다. **일반 batch/v1 Job과Deployment를같이render**한다. pre/post Helm hook, wave/controller orchestration, unbounded wait initContainer, Job이Deployment를삭제/재시작하는RBAC·kubectl을추가하지않는다. 서버가먼저시작해schema오류로재시도하는경계와Job완료뒤사용자가필요시rollout restart하는방법을문서화한다. Deployment자체삭제는일반Helm이자동재생성한다고가정하지않는다.

- Job은 필요한 SQL만 실행하고 끝난다. enabled 기본ON, timeout/backoff/resources 명시, rerun은 작고 명시적인 revision/content-aware 이름 등으로 Job immutable-spec 문제를 피한다. 완료 Job은 기본으로 보존해 GitOps prune/TTL로 반복 재실행되지 않게 한다.
- PG/CH **엔진은 설치하지 않는다**. 사용자/Secret 생성, DROP/TRUNCATE/reset과 기존 데이터 삭제는 금지한다. ‘기존 클러스터’와 ‘대상 logical DB가 이미 있음’을 혼동하지 않는다. 대상 DB 이름을 values로 받으며, 필요하면 **해당 application DB만 기존 계정으로 비파괴 생성**하는 작은 명시 옵션을 제공할 수 있다. 이미 있는 DB는 그대로 사용하고, 없는 DB를 만들 때 필요한 권한과 PG maintenance DB 연결을 명확히 한다. 자동 권한 승격/공유 DB 변경은 금지한다. DB 사전 생성이 필요한 모드라면 그 전제를 숨기지 않는다. 그 안에 필요한 schema/table/view/function을 준비한다.
- 기존 canonical DDL의 안전한 순서/정확한 type/기능을 재사용한다. 파일별 BEGIN/COMMIT과 PG transaction 경계를 처리한다. SQL안의function body·문자열을naive세미콜론split하지않는다. CH는기존안전한분할로직또는미리분리한statement파일로실행한다.
- 실패를삼키지않고 nonzero로끝내고, rerun은같은schema/data를보존한다. 일부DB만성공했어도다음실행에서안전하게완료가능해야한다. 광범위 migration/reset framework나카탈로그무결성플랫폼은추가하지않는다.
- **ACCESS 파일을맹목적으로실행하지말것.** 원본003_grants.sql 등은별도least-privilege runtime역할을가정하고동일owner 계정의권한을거부할수있다. 이번사용자는기존user를그대로쓰길원한다. 필요한 DDL/함수실행권한을실제계정모드에맞게처리하되계정생성·무관한DB/역할의권한회수·자동승격은하지않는다. 같은계정DDL/실행모드의권한조건을정직하게문서화한다.
- ClickHouse cluster의실제DDL전파/replication을추정하지않는다. 지원하는 endpoint/DB 또는 optional ON CLUSTER 범위를명시하고복잡한topology관리로확대하지않는다.
- SQL과작은runner는chart files/에포함해ConfigMap 등으로mount한다. 각ConfigMap과패키지크기한도를검증한다. 필요한Python/driver가선택이미지에있는지Dockerfile/manifest에서확인한다. 없는데있다고가정하지않는다.

## 4. 검증 — 패키지가 실제로 독립 동작해야 함

1. 기존 node-agent chart tree/기본 render를 baseline으로 보존한다. 그 코드는 변경하지 않는다. root common test는 charts/*/Chart.yaml 자동 검색하므로 새 chart를 실제 포함한다.
2. Helm3.21.3가 설치돼 있다. helm lint --strict, 기본/설치예시/사용자Secret key override/namespace/Job off+rerun revision/image digest/negative config를 작은회귀로검증한다. cluster lookup 없이기본render가능해야한다.
3. standalone사본과helm package archive를직접render하여동등성·LICENSE·SQL/runner포함·외부repo불필요를검증한다. defaults에현실secret값/privatecluster정보없는지검사한다. Secret는생성하지않고정확한secretKeyRef/volume-key만출력해야한다.
4. 실제0.4.0 Config/SignalLayer loader에 **synthetic secret files와 network차단 fixture**를사용해env/필수storage/모드/기본seed를검사한다. 별도private source가없어도chart의runner시험과설치가가능해야한다. source-loader호환시험과패키지독립시험을구분한다.
5. SQL runner 성공/재실행/오류 nonzero와credential 비노출을실행가능한작은테스트로검사한다. **가능하면격리된임시로컬PG/CH**에서한번준비→작은sentinel행→재실행/데이터보존과실제schema를확인한다. 기존test/운영DB에는접속하지않는다. 로컬DB가없으면실패/미실행을명시하고fake결과를실DB성공으로쓰지않는다.
6. 로컬DB smoke 예산: 단일validation process tree, PostgreSQL/ClickHouse 합계≤2CPU/3Gi, 각단계≤180초, synthetic≤5행, max fresh/repeat 각1회. task-owned container/port/volume만사용·정리, privileged/host mount/host-global설정금지. 없던대형DB이미지/패키지설치를무작정시도하지말고먼저cached/available경로확인후불가하면부분검증으로보고한다. 이미지build/push는하지않는다.
7. 기존 common/node-agent 회귀는 `IVIS_AGENT_BINARY`를제거하고실행해BPF/Agent실행을하지않는다. 테스트 passed/skipped를구분한다. 전역환경변경없이기존Python도구사용, narrow tests≤60초단위, native Helm실제출력을검사한다.
8. 기본SQLinventory와runner가공정본은docs/server-import.json 등으로source경로·해시·변환(있다면)·source미커밋상태와기준버전을기록한다. 구버전SQL누락을숨기기위해test를약화하지않는다. README/maintenance/validation/root차트목록과설치예시를같이갱신한다.

## 완료 산출물

- run_id `ivis-server-helm-040-20261024`.
- prompt는 이 파일, report `docs/ivis-server-helm-20261024-report.ko.md`, result `docs/ivis-server-helm-20261024-result.json`.
- 작은 증거/검증로그는 `docs/validation/ivis-server-20261024/` 또는 repo convention의 local evidence. 개발기록도이repo docs 안에둔다. 별도ivis-server repo를수정하지않는다.
- JSON은 status complete/partial/blocked, run_id, report_path, chart_path, 실제DDLinventory·권한/DB전제·Secret인터페이스·tests/명령/exit/standalone/package검증·SQL실행여부·기존node-agent/source보존·한계, cluster_mutated=false, publication=false를포함한다.
- 원자최종JSON은보고서/근거작성후발행하고결과를한국어로반환하고멈춘다. 준비된chart와실제DBJob실행/배포/pull/readiness를분리해서보고한다. 부모검증이마지막수락단계다.
