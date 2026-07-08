# menubucket R05 태스크 — 문서 정비 · URL 위젯 설치 · 성능 개선 (3트랙 병렬)

전제: M0~M2 완료(테스트 69/69, `dist/MenuBucket.app` 동작). 구조: `.context/impl/R01~R04-claude.md`.
빌드/테스트: 반드시 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build|test` (툴체인 혼용 금지, 꼬이면 `rm -rf .build`).

## 공통 계약 — URL 설치 v1 (Track B 코드와 Track C 문서가 일치해야 함)

### 지원 입력
1. GitHub repo URL: `https://github.com/{user}/{repo}` 또는 `https://github.com/{user}/{repo}/tree/{branch}[/{subdir}]`
2. 직접 아카이브 URL: `https://…/*.zip` 또는 `*.mbw`
3. 커스텀 스킴(딥링크): `menubucket://install?url=<percent-encoded-url>` — README 뱃지/웹사이트 버튼용

### 동작 (WidgetInstaller)
- GitHub URL → `https://codeload.github.com/{user}/{repo}/zip/refs/heads/{branch}` (branch 미지정 시 main → 실패 시 master 폴백). subdir 지정 시 그 안에서만 탐색.
- 아카이브 추출(임시 디렉토리) → **`widget.json`을 포함한 디렉토리를 전부 탐색** (repo 루트/서브디렉토리/멀티 위젯 지원).
- 각 후보: manifest 디코딩 검증(id·schemaVersion 필수) → 설치 확인 다이얼로그(위젯 이름·버전·**요구 권한 요약**: exec 커맨드/keychain/notifications) → `~/Library/Application Support/menubucket/widgets/<manifest.id>/`로 복사(기존 있으면 "업데이트" 문구, 권한 변경 시 재승인은 기존 승인 프레임이 처리).
- 핫 리로드가 자동 반영. 설치 결과는 완료 알림(성공 N개/실패 사유).
- **보안**: zip 경로 탈출(../) 차단, 다운로드 20MB·추출 50MB 제한, 심볼릭 링크 무시, 자동 권한 승인 절대 금지(첫 실행 시 승인 카드가 게이트).

### 진입점 3개
1. 메뉴바 우클릭 → "Install Widget from URL…" (URL 입력 다이얼로그)
2. URL 스킴: Info.plist에 `menubucket` 스킴 등록 + AppDelegate `application(_:open:)`
3. CLI 모드: `MenuBucket.app/Contents/MacOS/menubucket install <url>` — GUI 없이 설치 후 종료(exit 0/1), 향후 `mbk` CLI의 기반

## Track A — 성능 점검·개선 (Claude 에이전트 A)

**소유**: `Sources/MenubucketApp/Scheduler.swift`, `WidgetRuntime.swift`, `ThumbnailService.swift`, `Renderer/**`, `RootView.swift`, `Sources/MenubucketCore/**`(성능 관련 한정), `Tests/**`.
**금지**: `main.swift`, `StatusItemController.swift`, `PopupSurface.swift`, `WidgetInstaller*`(신규 포함), `scripts/`, `docs/`, `README.md`, `schema/`, `sdk/`, `widgets/`.

1. **측정 먼저** (개선 전 baseline 기록 — 노트에 수치 필수):
   - `bash scripts/build_app.sh && open dist/MenuBucket.app` 후 60초 대기 → `ps -o rss=,pcpu= -p <pid>` 3회 샘플(팝업 닫힘 유휴).
   - 유휴 CPU wakeup: `top -pid <pid> -l 3 -stats pid,cpu,mem,pageins | tail -3`.
   - 측정 후 앱 종료(`pkill -f dist/MenuBucket`).
2. **점검 항목** (각각 확인하고 문제면 수정):
   - 팝업 닫힘 중 타이머: interval/deadline 타이머가 닫힘 상태에서 돌지 않는지(runInBackground 위젯 제외). Timer 대신 다음 열림 시 재평가로 충분한 곳은 제거.
   - `@Published snapshots`(전체 dict) — 위젯 1개 갱신이 팝업 전체 뷰 무효화를 유발. `WidgetCardView`가 자기 스냅샷 변경에만 리렌더되도록 (예: snapshot Equatable 비교 후 발행 억제, 또는 per-widget ObservableObject 분리) 개선.
   - countdown `TimelineView` 팝업 닫힘 시 중단 확인(뷰 해제로 자동 중단인지 실측).
   - ThumbnailService: NSCache `totalCostLimit`(바이트 기반) 병행, 스케일 과대 생성 여부(pointSize×scale), 디스크 프루닝이 메인 차단 없는지.
   - ExecService/RuntimeSupervisor: 파이프 read 폴링 여부(있다면 readabilityHandler/async 시퀀스로), 좀비 프로세스 회수.
   - JSON 인코딩 핫패스: 스냅샷 persist가 갱신마다 동기 디스크 쓰기인지 → debounce/백그라운드로.
   - 앱 시작: 위젯 전체 즉시 실행하는지 → 팝업 첫 열림까지 지연(런치 비용 절감).
3. **개선 후 재측정** — 동일 방법, before/after 표로 노트에 기록. 목표: 유휴(팝업 닫힘) CPU ≈ 0.0~0.1%, RSS < 50MB, 위젯 1개 갱신 시 타 카드 리렌더 없음(코드 근거 설명).
4. 회귀 방지: 기존 테스트 전부 통과 + 발행 억제/캐시 관련 단위 테스트 추가 가능하면 추가.
5. 노트 → `.context/impl/R05-perf.md` (baseline/after 수치, 변경 파일, 근거, 남은 개선 후보).

## Track B — URL 위젯 설치 (Claude 에이전트 B)

**소유**: `Sources/MenubucketApp/WidgetInstaller.swift`(신규), `Sources/MenubucketApp/main.swift`, `StatusItemController.swift`, `scripts/Info.plist.template`(URL 스킴 추가만), `Tests/**`(installer 테스트 파일 신규만), `widgets/`(금지 아님but 불필요).
**금지**: Scheduler/WidgetRuntime/ThumbnailService/Renderer/RootView(트랙 A 소유), `docs/`, `README.md`, `schema/`, `sdk/`.

1. 위 "공통 계약 — URL 설치 v1" 전부 구현. 네트워크는 URLSession(async), GitHub API 불필요(codeload만).
2. URL 파싱/정규화·zip 안전 추출·widget.json 탐색은 **MenubucketCore**(`WidgetInstallSource.swift` 등 신규 파일)에 두고 단위 테스트: GitHub URL 변형 4종 파싱, 경로 탈출 zip 거부, 픽스처 zip(테스트에서 즉석 생성)에서 멀티 위젯 발견.
3. 설치 확인 다이얼로그는 NSAlert(위젯명/버전/권한 요약/Install·Cancel). CLI 모드는 다이얼로그 없이 진행하되 권한 요약을 stdout에 출력.
4. `install` 인자 모드: `main.swift` 초입에서 `CommandLine.arguments` 분기 — NSApplication 기동 전 처리, 성공/실패 메시지 stdout/stderr.
5. 검증: 빌드+테스트 통과, 로컬 픽스처 zip로 CLI 설치 end-to-end 1회(파일 배치 확인 후 정리). 실제 GitHub 다운로드는 네트워크 가용 시 1회만 시도(실패해도 태스크 실패 아님 — 노트에 기록).
6. 노트 → `.context/impl/R05-install.md`.

## Track C — 문서 전면 정비 (Codex)

**소유**: `docs/**`, `README.md`. **금지**: 나머지 전부.

1. `docs/GETTING-STARTED.md` — 설치(brew/수동) → 3분 안에 첫 위젯(hello 셸 위젯 변형 만들기) → 번들 위젯 4종 소개. 한국어, 스크린샷 자리는 placeholder 주석.
2. `docs/INSTALLING-WIDGETS.md` — 위 "URL 설치 v1" 계약 그대로 사용자 가이드화: GitHub URL/zip/딥링크 3경로, 권한 확인 화면 설명, 문제 해결(FAQ).
3. `docs/PUBLISHING.md` — 제작자용: 위젯 repo 권장 구조(루트 widget.json 또는 widgets/ 서브디렉토리), README에 넣을 설치 뱃지 스니펫(`menubucket://install?url=…` 링크 + `MenuBucket.app/Contents/MacOS/menubucket install <repo-url>` 커맨드), 버전 업데이트·권한 변경 시 재승인 동작, 체크리스트.
4. 기존 `WIDGET-SPEC.md`/`WORKFLOW.md`/`SCRIPT-RUNTIME.md` — 상호 링크 정리, M2-b 추가분(drag/fileThumbnail/settings UI/핀/검색) 반영 확인·보강.
5. `README.md` 전면 재구성 — 히어로 소개(3층 계층 다이어그램), Quick Start, 문서 인덱스 표, 위젯 4종 갤러리 표, 로드맵 링크. 기존 내용 유실 없이.
6. 검증: 문서 내 코드/커맨드가 실제 파일과 일치하는지 대조(widgets/ 예제 경로, schema 파일명). `.context/impl/R05-codex.md` 직접 쓰기 금지.
