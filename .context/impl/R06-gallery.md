# R06 Track B — 위젯 갤러리/레지스트리 (구현 노트)

구현 계약: R06-tasks.md "공통 계약 2 — 레지스트리 인덱스 v0.1" 전부. 테스트 133/133 통과(신규 RegistryTests 15개 포함).

## 신규/수정 파일

### `Sources/MenubucketCore/Registry.swift` (신규)
- **모델**: `RegistryIndex { schemaVersion, name?, updatedAt?(String 그대로), widgets }`,
  `RegistryWidgetEntry { id, name, description?, version?, author?, icon?, kind?, tags?, install{url}, permissions?{exec:[String]?, keychain?, notifications?}, homepage? }` — 계약 2 필드 그대로, 전부 Codable/Sendable.
- **관용 파싱**: `RegistryIndex.parse(data) -> (index, warnings)`.
  - schemaVersion != 1 → `RegistryError.unsupportedSchemaVersion` throw.
  - 엔트리별 독립 디코딩(`LossyEntries` — unkeyedContainer 수동 루프, 실패 시 Blank 디코드로 커서 전진): 필수 필드(id/name/install.url) 누락·타입 오류·비객체 엔트리는 **스킵 + warning 문자열 수집**, 나머지는 유지. 빈 문자열 id/name/install.url도 스킵.
- **`RegistryClient`**: 해석 순서 = 계약 그대로:
  1. env `MENUBUCKET_REGISTRY` — http(s)면 원격 fetch(캐시 경유), 아니면 로컬 경로(`~` 확장). 실패 시 warning 남기고 다음으로 폴백.
  2. 기본 원격 URL 상수 `RegistryClient.defaultRemoteIndexURL` (플레이스홀더 `https://raw.githubusercontent.com/menubucket/registry/main/index.json`).
  3. `bundledFallbacks: [URL]` 첫 존재 파일. 전부 실패 → `allSourcesFailed`.
  - **24h 디스크 캐시**: `~/Library/Caches/menubucket/registry-<host>-<djb2>.json` (URL별 파일 분리). fresh면 캐시 서빙(`source == .cache`), `forceRefresh`(수동 새로고침)면 무시. fetch 실패 시 **stale 캐시 폴백 + warning**. 캐시 쓰기는 best-effort.
  - 테스트 주입점: `Configuration(environment, defaultRemoteURL, bundledFallbacks, cacheDirectory, cacheMaxAge, fetch)` — fetch는 `@Sendable (URL) async throws -> Data` 클로저(기본 URLSession, HTTP != 200 오류, 5MB 응답 상한).
  - `LoadResult { index, source(.environmentFile/.remote/.cache/.bundled), warnings }`.

### `registry/index.json` (신규 샘플)
- 번들 위젯 5종 등재(aas-usage/otpeek/hello/clock-script/recent-files) — 각 manifest의 실제 id/name/version/icon/kind 사용, install.url은 `https://github.com/OWNER/REPO/tree/main/widgets/<dir>`.
- JSON은 주석 불가라 최상위 `"_comment"` 키로 OWNER/REPO 플레이스홀더 명시(디코더는 unknown key 무시; Codex 스키마가 additionalProperties:false면 `_comment` 허용 필요 — 조율 포인트).
- `jq empty` OK + `testShippedSampleIndexParses`가 이 파일을 직접 파싱 검증(5개 엔트리, warning 0).

### `Sources/MenubucketApp/GalleryView.swift` (신규)
- `GalleryWindowController.shared.show()` — 독립 NSWindow(560×640, resizable, `isReleasedWhenClosed=false`, NSHostingView). 팝업 아님.
- `GalleryModel`(@MainActor ObservableObject): load/refresh(force)/검색(이름+태그, 대소문자 무시)/설치 상태.
  - 번들 폴백 후보: `Bundle.main.resourceURL/registry/index.json`, `…/index.json`, 그리고 dev용 `#filePath` 기준 repo 루트 `registry/index.json` (앱 번들에 리소스 복사가 아직 없어도 소스 체크아웃 실행이면 오프라인 동작; build_app.sh 복사는 A/추후 몫).
  - 설치됨 판정: `WidgetRuntime.applicationSupportDirectory/widgets/<id>` 존재(인스톨러의 업데이트 판정과 동일 규칙). **WidgetInstaller/WidgetInstallFlow 내부에 의존하지 않음**.
  - `install(entry)` → `WidgetInstaller.shared.install(input: entry.install.url)` — 기존 GUI 플로우(확인 다이얼로그+권한 요약+완료 요약) 그대로. `onInstalled` 클로저는 StatusItemController 소유라 **건드리지 않고**, 뷰에 2초 Timer로 설치 상태 재검사(창 표시 중에만 동작)로 카드가 Installed로 전환.
- 카드: SF Symbol 아이콘, 이름, kind 배지(exec/script/workflow 색 구분), 버전, 설명, **권한 칩(exec: cmd / Keychain / Notifications — 표시용, 게이트는 첫 실행 승인 카드)**, Install / Installed+Reinstall. 헤더: 검색 필드 + 새로고침(forceRefresh) 버튼. 오류 시 재시도 화면, 하단에 로드 소스 표기.

### `Sources/MenubucketApp/StatusItemController.swift` (수정 — 메뉴 항목 1개)
- "Install Widget from URL…" 아래 "Widget Gallery…" 추가 + `openWidgetGallery` 액션(`Task { @MainActor in … show() }`). 그 외 미수정.

### `Tests/MenubucketCoreTests/RegistryTests.swift` (신규, 15 케이스)
- 파싱: 정상 인덱스 전 필드, 고장 엔트리 5종 스킵+경고(이름 누락/install 누락/비객체/빈 id/빈 url), schemaVersion 2 거부, malformed JSON 거부, **repo 샘플 index.json 직접 검증**.
- 폴백 순서: env 로컬 경로 우선(원격 fetch 미호출 assert), env 원격 URL fetch, env 고장 → 기본 원격 폴백+경고, 원격 실패 → 번들 폴백, 전부 실패 throw.
- 캐시: 2회차 캐시 서빙(fetch 1회), forceRefresh 재fetch, 만료 후 재fetch, fetch 실패 시 stale 캐시+경고, URL별 캐시 파일명 분리.

## 검증
- `DEVELOPER_DIR=… swift build` OK (Track A의 Package.swift 편집 중 일시 실패 → 재시도로 해소).
- `swift test` **133/133 통과** (기존 + Track A 신규 + Registry 15).
- 갤러리 창 렌더는 GUI — 메인 세션 스모크 대상: 우클릭 메뉴 → "Widget Gallery…" → 카드 5개 + 검색/새로고침 + Install 플로우.

## 남은 사항 / 조율
- 기본 원격 URL은 플레이스홀더 — 실제 레지스트리 repo 확정 시 `RegistryClient.defaultRemoteIndexURL` 한 줄 교체.
- 패키징된 .app에서 오프라인 폴백을 쓰려면 build_app.sh가 `registry/index.json`을 Resources에 복사해야 함(scripts/는 B 금지 — A 또는 후속).
- `_comment` 키: Codex의 `schema/registry-0.1.json`이 additionalProperties를 막으면 스키마에서 `_comment` 허용하거나 샘플에서 제거 필요.
- 갤러리의 설치됨 갱신은 폴링(2s) — StatusItemController의 `onInstalled` 단일 클로저를 존중한 선택. 추후 NotificationCenter 이벤트로 교체 가능.
