# menubucket R08 태스크 — 갤러리 설치 수정 · 앱 설정/모니터링 · 위젯 빌더 UI (2트랙)

전제: R07 완료(테스트 141, URL 설치 실검증 — 슬래시 브랜치/사이즈캡 수정 반영). 사용자 피드백:
1. 갤러리 Install이 download fail — 원인: registry install.url 5개 전부 private repo(jiunbae/menubucket) → 무인증 codeload 404.
2. 사용자가 직접 위젯을 만들 수 있는 UI 필요 (iOS Shortcuts/automation 류 참고).
3. 메뉴바 아이콘 변경, 성능 관리, 모니터링 주기 등 앱 옵션 필요.

빌드/테스트: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build|test`. 커밋 금지(메인 세션이 검증 후 커밋).

## 공통 계약

### C1. 번들 설치 (레지스트리 v0.1 추가 필드)
- entry에 옵셔널 `"install": { "url": "...", "bundled": "<Resources/widgets/ 디렉토리명>" }`.
- 갤러리는 `bundled`가 있고 앱 번들 리소스에 해당 디렉토리가 존재하면 **네트워크 없이 로컬 복사 설치**(HeadlessInstaller.install과 동일 결과: `~/…/widgets/<manifest.id>/`). 없으면 `url`로 폴백. mbk/외부는 `url` 사용.

### C2. 빌더 진입점
- Track B는 `@MainActor final class WidgetBuilderController { static let shared; func show(runtime: WidgetRuntime) }` 제공 (신규 파일, 이 시그니처 고정).
- Track A가 우클릭 메뉴 "Create Widget…"과 온보딩/푸터 "+ 위젯 추가"에 연결.

### C3. AppPrefs (Track A 소유, 신규 `Sources/MenubucketApp/AppPrefs.swift`)
- 저장: `~/Library/Application Support/menubucket/app-prefs.json`.
- 키: `menuBarSymbol: String`(기본 "tray.full"), `refreshMultiplier: Double`(0.5/1/2/4 — 모든 위젯 staleAfter·interval에 곱), `pauseWhenClosed: Bool`(배터리 세이버: 팝업 닫힘 중 runInBackground 포함 전체 정지), `launchAtLogin: Bool`.

## Track A — 갤러리 수정 + 설정/모니터링 (Claude 에이전트 A)

**소유**: `Sources/MenubucketApp/GalleryView.swift`, `StatusItemController.swift`, `RootView.swift`(진입점 연결만), `WidgetRuntime.swift`, `Scheduler.swift`, 신규 `AppPrefs.swift`/`AppSettingsView.swift`/`RefreshStats.swift`, `Sources/MenubucketCore/Registry.swift`, `registry/index.json`, `schema/registry-0.1.json`, `Tests/**`(관련 신규).
**금지**: `Builder/**`, `WidgetScaffold*`(B 소유), docs/, README.md, sdk/, scripts/, widgets/.

1. **갤러리 설치 수정** (C1): Registry 모델에 `install.bundled` 추가, GalleryView Install → 번들 우선 로컬 설치(성공 시 "Installed" 상태 즉시 갱신 + 핫 리로드), 실패 메시지는 사유 표시(현재 generic fail이면 개선). `registry/index.json`: 5개 entry에 `bundled` 추가 + 외부 url은 public repo로 교체 — aas-usage → `https://github.com/Open330/aas`, recent-files → `https://github.com/jiunbae/file-stack` (기본 브랜치 기준 — PR 머지 전까지는 bundled 경로가 커버), hello/clock-script/otpeek는 url 유지하되 `_comment`로 private 명시. 스키마 반영.
2. **앱 설정 창** `AppSettingsView`(독립 NSWindow, 우클릭 메뉴 "Settings…"):
   - 일반: 메뉴바 아이콘 선택(SF Symbol 프리셋 그리드 12종 + 자유 입력 + 실시간 적용 — StatusItemController가 AppPrefs 구독), 로그인 시 시작(`SMAppService.mainApp.register/unregister`, 실패 시 안내).
   - 성능: refreshMultiplier 세그먼트(0.5×/1×/2×/4×), pauseWhenClosed 토글 — Scheduler가 정책 반영(멀티플라이어는 interval·staleAfter 판정에 적용).
   - 모니터링: 위젯별 통계 테이블 — 마지막 갱신 시각, 성공/실패 횟수, 평균·최근 소요 ms, 상태. `RefreshStats`(WidgetRuntime이 refresh 완료 시 기록, 메모리+간단 JSON 지속). "Open Logs Folder" 버튼(`~/Library/Logs/MenuBucket`).
3. **진입점 연결** (C2): 우클릭 메뉴 "Create Widget…" + 온보딩 빈 상태와 푸터 "+ 위젯 추가"→ `WidgetBuilderController.shared.show(runtime:)`. **B가 파일을 아직 안 만들었으면 컴파일 실패하므로, 연결 코드는 `#if canImport` 불가 — 대신 마지막에 통합 확인하고, B 완료 전이라면 프로토콜 없이 직접 호출 코드만 작성해두고 빌드는 B 파일 생성 후 통과되는 것을 확인**(두 에이전트 동시 작업이므로 최종 빌드는 메인 세션 몫 — 자신의 파일 단위 문법에 집중).
4. 테스트: Registry bundled 필드 파싱, AppPrefs 라운드트립, RefreshStats 집계, refreshMultiplier 정책 계산(Core로 뽑을 수 있으면 Core에).
5. 노트 → `.context/impl/R08-settings.md`.

## Track B — 위젯 빌더 UI (Claude 에이전트 B)

**소유**: `Sources/MenubucketApp/Builder/**`(신규 디렉토리), `Sources/MenubucketCore/WidgetScaffold.swift`(신규), `Tests/MenubucketCoreTests/WidgetScaffoldTests.swift`(신규).
**금지**: 그 외 전부 (특히 GalleryView/StatusItemController/RootView/WidgetRuntime/Registry — A가 동시 수정 중).

iOS Shortcuts의 "액션 카드를 쌓는" 멘탈 모델을 차용한 **3단계 위저드** (창 제목 "Create Widget"):

1. **Step 1 — 소스 선택** (카드 3종):
   - "Run a command" — 커맨드라인 입력(공백 분리 args), 시험 실행 버튼(ExecService, 출력 미리보기 상단 20줄), stdout이 JSON이면 자동 감지 배지
   - "Watch a folder" — 폴더 선택(NSOpenPanel) + limit/정렬
   - "Static text" — 데모/학습용 고정 텍스트
2. **Step 2 — 표시 선택** (프리셋 카드 + **라이브 프리뷰** 우측 분할):
   - 리스트 / 테이블(컬럼=JSON 키 다중 선택) / 단일 값+선형 게이지(값 경로+최대값) / 플레인 텍스트
   - JSON 소스면 시험 실행 결과의 키 목록에서 필드 매핑(경로 선택 드롭다운 — 배열이면 forEach)
   - 프리뷰: 실제 파이프라인 재사용 — 소스 1회 실행 → `WorkflowEngine.evaluate` → `ViewTreeRenderer` (스크린샷 아님, 라이브 렌더)
3. **Step 3 — 메타**: 이름, SF Symbol 아이콘(프리셋 그리드), 버킷 그룹(기존 그룹 드롭다운+신규 입력), 갱신(onOpen만 / interval 30s·1m·5m·15m), [Create] → App Support에 디렉토리 생성 → 핫 리로드가 반영. 완료 화면에 "Open widget folder" + "docs/WIDGET-SPEC.md 보기" 링크.

구현 규칙:
- 생성 로직은 **Core `WidgetScaffold`**: 위저드 상태 struct → `widget.json`(+`workflow.json`) 문자열/파일 생성. exec+viewtree(커맨드가 UINode 출력할 리 없으므로 커맨드 소스는 **workflow의 exec source**로 생성해 표시 프리셋과 결합), 폴더 소스는 fs.directory workflow, static text는 exec 없이 view만 있는 workflow. 산출물은 기존 스키마(`schema/widget-0.1.json`/`workflow-0.1.json`)와 `mbk validate` 통과 필수.
- 단위 테스트: 프리셋×소스 조합별 scaffold 산출 JSON을 `Manifest.decode`/`WorkflowDefinition.decode`로 재파싱 + 대표 케이스 `WorkflowEngine.evaluate` 스모크. 최소 10케이스.
- C2 시그니처의 `WidgetBuilderController` 제공(창 관리, 재사용).
- exec 소스 생성 시 manifest `permissions.exec`에 해당 커맨드 allowlist 자동 선언(첫 실행 승인 카드가 게이트 — 빌더가 승인 우회 금지).
6. 노트 → `.context/impl/R08-builder.md`.
