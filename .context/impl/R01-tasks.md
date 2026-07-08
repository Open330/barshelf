# menubucket M0 구현 태스크 (R01)

캐노니컬 스펙: `/Users/jiun/workspace/menubucket/.context/plans/R01-merged.md` — 반드시 먼저 읽을 것 (§2 아키텍처, §3 manifest, §4 M0 검증 기준).
참조 패턴: `/Users/jiun/workspace/file-stack/Sources/FileStackApp/main.swift` (NSStatusItem+NSPopover 라이프사이클), `/Users/jiun/workspace/file-stack/scripts/` (앱 번들 조립).

## 공통 계약 (두 에이전트 모두 준수)

- SwiftPM executable, swift-tools 5.9, macOS 13+, **외부 의존성 0**.
- Package.swift 타깃 (고정 — 변경 금지):
  - `MenubucketCore` (라이브러리, UI 무의존)
  - `MenubucketApp` (executableTarget, depends: MenubucketCore)
  - `MenubucketCoreTests` (testTarget)
- 실행 파일 프로덕트명: `menubucket`, 앱 번들명: `MenuBucket.app`, 번들 ID: `dev.menubucket.app`.
- 위젯 디렉토리 탐색 순서: `./widgets/`(개발 모드, cwd 기준) → `~/Library/Application Support/menubucket/widgets/`. 각 위젯은 `<dir>/<widget-name>/widget.json`.

## Task A — Swift 패키지 전체 (담당: Claude 에이전트)

**소유 파일**: `Package.swift`, `Sources/**`, `Tests/**`, `widgets/**`. (scripts/, schema/, README.md는 건드리지 말 것 — 다른 에이전트 소유)

### A1. MenubucketCore

- `UINode.swift`: struct 기반 Codable. `type: String` 판별자 + 옵셔널 필드 방식(전방 호환 — 알 수 없는 type도 디코딩은 성공해야 함).
  - v0 노드: `vstack hstack list section text image progress button badge banner empty divider spacer`.
  - 필드: `id`, `type`, `children: [UINode]?`, `items: [UINode]?`(list), `text`, `role`("title"|"body"|"caption"|"code"), `lineLimit`, `monospacedDigit`, `spacing`, `title`(section/button/empty), `subtitle`(empty), `source: ImageSource?`(`{kind:"sfSymbol", name}`), `size`(image pt), `tint`/`tone`/`foreground`("primary"|"secondary"|"tertiary"|"accent"|"good"|"warning"|"danger"|"neutral"), `value: Double?`(progress 0...1), `label`(progress), `icon`(sfSymbol명, button/empty), `action: NodeAction?`, `padding: Double?`, `widthFill: Bool?`.
  - `NodeAction`: `{type: "copyText"|"openURL"|"openFile"|"revealFile"|"refresh"|"event", value/url/path/id/toast 옵셔널}`.
- `Manifest.swift`: R01-merged §3 스키마의 M0 부분집합 Codable — `schemaVersion, id, name, icon, bucket{group, order, size}, entry{kind}, source{kind, command:[String], discover:[String], timeoutMs, output("viewtree"|"data"), adapter}, refresh{onOpen, interval, staleAfterSec}`. permissions/settings는 디코딩만 하고 M0에선 미사용(필드 존재해도 실패하지 않게).
- `WidgetSnapshot.swift`: 위젯 런타임 상태 모델 — `viewTree: UINode?`, `updatedAt: Date?`, `error: String?`, `isLoading` 등. 렌더 캐시 직렬화(JSON) 포함.

### A2. MenubucketApp

- `main.swift`: `NSApplication` + `.accessory` 활성화 정책(개발 중 `swift run` 대응), AppDelegate.
- `StatusItemController.swift`: file-stack 패턴 — variableLength status item, SF Symbol 아이콘("tray.full" 계열), `sendAction(on: [.leftMouseUp, .rightMouseUp])`, 좌클릭 팝업 토글, 우클릭 NSMenu(Refresh All / Quit).
- `PopupSurface.swift`: 프로토콜(`show(relativeTo:)/hide/isShown`) + `PopoverSurface: NSPopover` 구현(behavior .transient로 시작, `NSHostingController` 콘텐츠, 크기 360×480 기본).
- `ExecService.swift`: 바이너리 탐색(`$ENVVAR` → `~` 확장 절대경로 후보 → `PATH` 문자열이면 env PATH 검색 + `/opt/homebrew/bin:/usr/local/bin:~/.cargo/bin` 폴백), `Process` 실행은 백그라운드 큐, `timeoutMs` 강제(kill), stdout 1MB 제한, stderr 별도 파이프 drain, no shell(`executableURL` 직접).
- `WidgetRuntime.swift` (`ObservableObject`): manifest 로드 → 위젯별 상태 발행. refresh 트리거: 팝업 열림 시(`onOpen` + stale 판정), 수동(Refresh All/위젯 버튼), interval은 non-null일 때만 Timer. in-flight coalescing, 실패 시 last-good-render 유지 + `error` 세팅. `output=viewtree`면 stdout JSON→UINode 디코드, `output=data`면 adapter 레지스트리(`[String: (Data) -> UINode]`) 적용.
- `Adapters/AasUsageAdapter.swift`: `aas usage --json` 스키마(`{"accounts":[{provider,name,email,active,plan,planLabel,headline,error,meters:[{label,usedPct,resetMs}]}]}`) → UINode 트리. provider별 section, 계정 행: active 도트+이름+plan 배지, 미터 행: label+linear progress+% (remaining <10 danger / <30 warning / else good), 계정 error는 danger 캡션. 헤더: "aas" 타이틀 + 최악 remaining 요약 + 갱신 상대시간. 하단: Refresh 버튼(action refresh).
- `Renderer/ViewTreeRenderer.swift`: UINode → SwiftUI 재귀 렌더러. text role 매핑(title=13 semibold, caption=.caption .secondary, code=monospaced), progress=ProgressView(value:) tint 매핑, button=Button+ActionRouter, 알 수 없는 type은 "⚠︎ unsupported: {type}" placeholder. 반복 노드는 `id` 기반 ForEach identity.
- `ActionRouter.swift`: copyText(NSPasteboard+선택적 토스트 대신 간단 피드백), openURL, openFile/revealFile(NSWorkspace), refresh(런타임 콜백), event는 M0에서 no-op 로그.
- `RootView.swift`: bucket.group 기준 페이지 구성(그룹 내 order 정렬). 페이지 전환: 좌우 화살표 버튼 + 하단 도트 + 키보드 ←/→·⌘1..9(`onKeyPress` 또는 로컬 NSEvent 모니터). 위젯 카드: 이름 헤더 + 콘텐츠 + error 시 warning 배너("Showing cached data: …") + updatedAt 캡션. 로딩 시 캐시 우선 표시.

### A3. widgets/ 예제 2종

- `widgets/aas-usage/widget.json`: entry exec, `command: ["aas","usage","--json"]`, `discover: ["$AAS_BIN","~/.cargo/bin/aas","/opt/homebrew/bin/aas","/usr/local/bin/aas","PATH"]`, output data, adapter "aas-usage", refresh onOpen+staleAfterSec 600, bucket {group:"Agents", order:20, size:"M"}.
- `widgets/hello/widget.json` + `widgets/hello/hello.sh`(실행권한): 셸 스크립트가 UINode JSON(viewtree) 출력 — 현재 시각 text, 간단 progress, copyText 버튼 포함(액션 시연). output viewtree, refresh interval 60. bucket {group:"Demo", order:10, size:"S"}.

### A4. Tests

`Tests/MenubucketCoreTests/`: ① UINode 라운드트립+알 수 없는 type 디코딩 성공, ② manifest 파싱(예제 widget.json 그대로), ③ 스냅샷 직렬화. 예제 aas JSON 픽스처로 adapter 출력 구조 검증은 App 타깃이라 불가 — adapter를 Core로 내려도 좋음(그 경우 Core에 두고 테스트 포함, 단 Core는 Foundation만 사용).

### A5. 검증 (필수)

`swift build && swift test` 통과 확인. `swift run`은 GUI 상주라 실행하지 말 것(빌드 성공까지만). 완료 후 구현 노트를 `.context/impl/R01-claude.md`에 저장: 파일 목록, 설계 이탈 사항, 알려진 한계, 다음 단계 제안.

## Task B — 빌드 파이프라인·스키마·문서 (담당: Codex 에이전트)

**소유 파일**: `scripts/**`, `schema/**`, `README.md`. (Package.swift, Sources/, Tests/, widgets/는 절대 건드리지 말 것 — 다른 에이전트가 동시 작업 중)

- B1. `scripts/build_app.sh`: file-stack의 `scripts/build_app.sh`를 참조해 이식 — `swift build -c release` 후 `MenuBucket.app` 번들 조립(Contents/MacOS/menubucket, Info.plist, 리소스로 widgets/ 복사), ad-hoc codesign. Info.plist: `LSUIElement=true`, 번들 ID `dev.menubucket.app`, 최소 macOS 13.0. 실행 파일명은 SwiftPM 프로덕트 `menubucket` 가정.
- B2. `scripts/Info.plist.template` (build_app.sh가 사용).
- B3. `schema/widget-0.1.json`: R01-merged §3 manifest의 JSON Schema (draft-07 이상). M0 부분집합 필수/타입 정의 + permissions/settings는 관대하게.
- B4. `README.md`: 프로젝트 소개(한 문단), 아키텍처 요약(3층 실행 계층), 빌드/실행 방법(`swift build`, `scripts/build_app.sh`), 위젯 제작 quickstart(widget.json 예시 — viewtree 셸 스크립트), 로드맵 링크(`.context/plans/R01-merged.md`).
- 완료 노트는 최종 응답 메시지로 요약(별도 파일 저장 불필요 — 자동 캡처됨). `.context/impl/R01-codex.md` 파일을 직접 쓰지 말 것.
