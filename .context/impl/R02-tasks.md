# menubucket M1 구현 태스크 (R02)

전제: M0 완료 (`swift build`/`swift test` 15/15 통과). 캐노니컬 스펙: `.context/plans/R01-merged.md` §4 M1 행. 기존 코드 구조는 `.context/impl/R01-claude.md` 참조.

주의: 테스트 실행은 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CommandLineTools에 XCTest 없음).

## 공통 계약 (신규 — 두 에이전트 문서/코드 일치 필수)

### countdown progress 노드 (UINode 확장)

```jsonc
{ "type": "progress", "style": "ring",            // "linear" | "ring"
  "countdown": { "from": 1783442400000, "until": 1783442430000 },  // epoch ms; value 대신 사용 가능
  "labelFrom": "remainingSeconds",                 // ring 중앙에 남은 초 표시
  "tintRules": [{ "whenRemainingLtSeconds": 10, "tint": "danger" }] }
```
- 호스트가 팝업 열림 중 1초 틱(TimelineView)으로 자체 갱신 — 스크립트 재실행 불필요.

### manifest v0.1 추가 필드 (M0 부분집합 → 전체)

- `refresh.deadlineField`(사용 안 함 — adapter가 nextRefreshAt 반환으로 대체, 스키마에는 예약), `refresh.watchPaths: [String]`, `refresh.runInBackground: Bool`
- `statusItem: { mode: "none"|"icon"|"text"|"dynamic", icon, labelFrom, tooltipFrom }` (M1은 디코딩+none만 동작, 표시 M2)
- `permissions.exec[]: { command, allowedArgs: [[String]] ("*" 와일드카드 허용), env: [String], maxOutputBytes, sensitiveOutput }`
- `permissions.keychain: Bool`, `settings[]` (디코딩만, UI는 M2)
- `entry.kind`: `"exec"` 외 `"script"|"workflow"|"builtin"`은 디코딩 허용 + "unsupported in M1" 오류 카드 표시

### 선언적 액션 확장

- `run`: `{ "type": "run", "command": ["aas","switch","work"], "thenRefresh": true }` — manifest `permissions.exec`의 command+allowedArgs 패턴과 매칭될 때만 실행, 불일치 시 차단+로그.
- `copyText`에 `clearAfterSec: Int?` — sensitive 코드용 클립보드 자동 소거(NSPasteboard changeCount 확인 후 동일할 때만 소거).

## Task A — Swift 전체 (담당: Claude 에이전트)

**소유**: `Package.swift`, `Sources/**`, `Tests/**`, `widgets/**`. (schema/, docs/, README.md, scripts/ 금지 — 타 에이전트 소유)

1. **Manifest 확장**: 위 공통 계약 전체 디코딩. 스키마 위반/미지원 entry.kind는 위젯 카드에 명확한 오류 상태로 표시(로드 자체는 성공).
2. **Scheduler** (`Sources/MenubucketApp/Scheduler.swift` 신설, 정책 로직은 Core에 두고 테스트): 트리거 5종 —
   - `onOpen`(stale 판정: `staleAfterSec` 경과), `manual`, `interval`(팝업 열림 최소 5s / 닫힘 시 `runInBackground==true`만 4배 완화 주기),
   - `deadline`: adapter/viewtree 결과가 `nextRefreshAtMs`를 반환하면 그 시각에 정확히 1회 재실행 (Timer, 팝업 닫히면 취소·열림 시 재평가),
   - `watch`: `refresh.watchPaths` FSEvents 감시(250ms debounce), 팝업 닫힘 중엔 pending 마크만 → 열림 시 일괄 처리. file-stack `DirectoryWatcher.swift` 패턴 이식(`Sources/MenubucketApp/DirectoryWatcher.swift`).
   - 추가: `NSWorkspace.didWakeNotification` → stale 위젯 일괄 갱신.
   - 공통: in-flight coalescing 유지, 연속 실패 지수 백오프(15s→60s→300s 캡, 성공 시 리셋).
3. **Adapter 계약 승격**: 동기 `(Data) -> UINode` → `(Data, AdapterContext) async throws -> AdapterResult{ viewTree, nextRefreshAtMs?, statusText? }`. `AdapterContext`는 manifest allowlist 안에서 추가 exec 가능(`runAllowed(command:args:)`) + env 주입. 기존 aas adapter 마이그레이션.
4. **otpeek 위젯** (`widgets/otpeek/widget.json` + adapter "otpeek"):
   - source: `otpeek list --json` (sensitiveOutput true), discover: `$OTPEEK_BIN`→`~/.cargo/bin/otpeek`→brew→PATH.
   - adapter: totp 계정 필터→각 계정 `otpeek code <id> --json`(allowedArgs `["code","*","--json"]`) 병렬 실행→행: issuer/accountName + countdown ring(from=validFrom, until=validUntil) + 그룹핑된 코드(`728 419`) + copyText 액션(`clearAfterSec: 30`). `nextRefreshAtMs = min(validUntil)+250`.
   - Keychain 패스워드 주입: `KeychainStore`(service `dev.menubucket`, account `otpeek-vault-password`) 조회 → 있으면 자식 프로세스 env `OTPEEK_VAULT_PASSWORD`로 주입(manifest `permissions.keychain: true` + env 선언 필요). 없고 otpeek이 패스워드 오류 반환 시 오류 카드에 설정 방법 안내: `security add-generic-password -s dev.menubucket -a otpeek-vault-password -w`.
   - otpeek 미설치 시: 오류 카드 + 설치 안내 (다른 위젯 무영향).
5. **countdown 렌더링**: 공통 계약대로 UINode 확장 + ViewTreeRenderer에 ring(원형 trim + 중앙 남은 초) / linear countdown 구현. 팝업 닫히면 틱 중단.
6. **스와이프 페이저**: RootView 페이지 전환을 트랙패드 두 손가락 수평 스와이프로 — NSEvent scrollWheel(phase 추적, 수평 우세 판정) 로컬 모니터 또는 NSViewRepresentable. 러버밴드/스냅 애니메이션, 기존 도트·←/→·⌘1..9 유지. 세로 스크롤(버킷 내)과 충돌 금지.
7. **핫 리로드**: 위젯 디렉토리(개발 `./widgets/` + 사용자 디렉토리) FSEvents 감시 → manifest 재스캔, 위젯 id 기준 스냅샷 보존, 제거된 위젯 정리.
8. **sensitive 처리**: `sensitiveOutput: true` exec의 stdout 로그 금지, sensitive 위젯 스냅샷은 디스크 캐시 제외(메모리만).
9. **선언적 액션**: 공통 계약 `run`/`copyText.clearAfterSec` 구현 (ActionRouter + allowlist 매처는 Core에 두고 테스트).
10. **테스트 추가**: allowlist 매처(와일드카드 포함/차단), 스케줄 정책(stale/백오프 계산), countdown 노드 디코딩, otpeek adapter(픽스처: list+code JSON), manifest 전체 디코딩.
11. **검증**: `swift build` + `DEVELOPER_DIR=... swift test` 전부 통과. 완료 노트 → `.context/impl/R02-claude.md` (파일 목록, 이탈, 한계, 다음 단계).

## Task B — 스키마·문서 (담당: Codex 에이전트)

**소유**: `schema/**`, `docs/**`, `README.md`. (Package.swift, Sources/, Tests/, widgets/, scripts/ 절대 금지 — 타 에이전트가 동시 작업 중)

1. `schema/widget-0.1.json` 확장: 위 "manifest v0.1 추가 필드" 반영 (statusItem, permissions.exec 상세, keychain, settings, refresh.watchPaths/runInBackground/deadlineField 예약).
2. `schema/uinode-0.1.json` 신설: UINode v0.1 JSON Schema — R01-merged §3 노드 목록 + 위 countdown progress 계약 + NodeAction(run/copyText.clearAfterSec 포함).
3. `docs/WIDGET-SPEC.md` 신설: 위젯 제작자용 스펙 문서 — manifest 필드 표, UINode 노드별 예제, 액션 표, 갱신 모델(onOpen/interval/deadline/watch), sensitive 규칙, 예제 3종(hello viewtree / aas data+adapter / otpeek) 워크스루. 한국어.
4. `README.md` 갱신: otpeek 위젯 섹션(Keychain 설정 커맨드 포함), 스와이프/키보드 조작법, WIDGET-SPEC 링크.
5. `.context/impl/R02-codex.md` 파일을 직접 쓰지 말 것 (최종 메시지가 자동 캡처됨). 검증: `jq empty schema/*.json`.
