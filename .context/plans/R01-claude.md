# menubucket — 스크립터블 메뉴바 위젯 플랫폼 기획서 (R01)

- 관점: 시스템 아키텍처 + 기존 코드베이스 통합 전략
- 작성일: 2026-07-07
- 사전 조사 대상: `/Users/jiun/workspace/file-stack` (Stashbar), `/Users/jiun/workspace/otpeek` (OTPeek), `/Users/jiun/workspace-open330/aas` (aas)
- 상태: 초안 (코드 직접 분석 기반)

---

## 0. 요약

menubucket은 **"위젯 = 데이터 프로그램, 렌더링 = 호스트"**를 원칙으로 하는 macOS 메뉴바 플랫폼이다.
사용자는 스크립트/CLI가 **선언적 JSON 뷰 트리**를 출력하도록 작성하고, 호스트(Swift 앱)가 이를 **SwiftUI로 네이티브 렌더링**한다. 여러 위젯은 하나의 팝업 안에서 페이지(스와이프)로 전환된다.

핵심 결정 3가지:

| 결정 | 선택 | 근거 |
|---|---|---|
| 호스트 앱 | Swift (SwiftPM executable, AppKit 셸 + SwiftUI 콘텐츠) | Stashbar가 동일 구조로 검증됨. 팝업 관리/빌드 파이프라인 코드 직접 이식 가능 |
| 스크립트 계층 | 2계층: **서브프로세스 데이터소스**(어떤 언어든) + **임베디드 JavaScriptCore**(인터랙션 로직) | otpeek/aas가 이미 `--json` CLI 계약을 제공. JSC는 시스템 프레임워크라 배포 부담 0 |
| UI 정의 | JSON 뷰 트리 (server-driven UI) → SwiftUI 매핑 | xbar의 단순함 + Raycast의 네이티브 렌더링 품질을 동시에 취함 |

---

## 1. 전체 아키텍처

### 1.1 레이어 다이어그램

```
┌──────────────────────────────────────────────────────────┐
│ Host App (Swift, LSUIElement agent)                       │
│                                                           │
│  ┌────────────┐  ┌───────────────┐  ┌──────────────────┐  │
│  │ StatusItem │  │ Panel/Popover │  │ Settings Window  │  │
│  │ Controller │  │ (페이지네이션)  │  │ (위젯 관리)       │  │
│  └─────┬──────┘  └──────┬────────┘  └──────────────────┘  │
│        │                │ SwiftUI 렌더러                   │
│        │         ┌──────┴────────┐                        │
│        │         │ ViewTree →    │  ← 선언적 UI 스키마      │
│        │         │ SwiftUI 매퍼  │     (JSON, 버전드)       │
│        │         └──────┬────────┘                        │
│  ┌─────┴────────────────┴─────────────────────────────┐   │
│  │ Widget Runtime                                     │   │
│  │  · Scheduler (interval / deadline / fsevents /     │   │
│  │    on-open 트리거)                                  │   │
│  │  · State Store (위젯별 KV, JSON 파일)                │   │
│  │  · Event Dispatcher (click/key/swipe → 액션 실행)    │   │
│  └───────┬──────────────────────────┬─────────────────┘   │
│          │                          │                     │
│  ┌───────┴─────────┐      ┌─────────┴──────────┐          │
│  │ Exec Provider   │      │ JS Provider        │          │
│  │ (서브프로세스,    │      │ (JavaScriptCore,    │          │
│  │  stdout JSON)   │      │  위젯별 컨텍스트)     │          │
│  └───────┬─────────┘      └────────────────────┘          │
└──────────┼────────────────────────────────────────────────┘
           │ exec + JSON stdout
   ┌───────┼──────────────┬─────────────────┐
   │ otpeek code --json   │ aas usage --json │ 임의 스크립트 (py/ts/sh/lua…)
```

### 1.2 호스트 앱: Swift 선택 근거

- **Stashbar(file-stack)가 정확히 같은 형태의 앱을 SwiftPM 패키지로 검증**했다. `Package.swift`(swift-tools 5.9, macOS 13+) + 라이브러리 타깃(코어 로직) + 실행 타깃(UI) 구조, `scripts/build_app.sh`가 `.app` 조립·`Info.plist`(LSUIElement)·codesign까지 처리한다. 이 빌드 파이프라인을 그대로 가져온다.
- 메뉴바 UX의 품질(팝업 포지셔닝, 이벤트 모니터, 드래그&드롭)은 AppKit 접근 없이는 불가능 — Electron/Tauri 배제.
- Rust 공유 코어(otpeek 방식의 UniFFI + xcframework)는 **지금은 도입하지 않는다.** 크로스플랫폼 요구가 없고, FFI 빌드 파이프라인(`build-core.sh`의 타깃별 빌드 + lipo + bindgen)은 초기 속도를 죽인다. 단, 뷰 트리 파서/스케줄러를 코어 라이브러리 타깃(`MenubucketCore`)으로 분리해 두면 추후 Rust 치환 경로가 열려 있다.

패키지 구조 초안:

```
menubucket/
├── Package.swift
├── Sources/
│   ├── MenubucketCore/        # 뷰트리 모델, manifest 파서, 스케줄러 (UI 무의존, 테스트 대상)
│   └── MenubucketApp/         # AppKit 셸 + SwiftUI 렌더러 + 런타임
├── Tests/MenubucketCoreTests/
├── widgets/                   # 번들/예제 위젯
└── scripts/                   # build_app.sh, entitlements (Stashbar에서 이식)
```

### 1.3 팝업 구현: NSPopover → NSPanel 단계 전환

Stashbar의 `Sources/FileStackApp/main.swift` 패턴을 M0에 그대로 이식한다:
- `NSStatusBar.system.statusItem(withLength:.variableLength)`, `sendAction(on:[.leftMouseUp,.rightMouseUp])` — 좌클릭 팝업 토글, 우클릭 `NSMenu`(설정/종료).
- `NSPopover(behavior:.applicationDefined)` + `NSHostingController` + 커스텀 `positionPopover`(status button 아래 중앙 정렬, `screen.visibleFrame` 클램프).
- 닫힘 처리: 글로벌 `NSEvent.addGlobalMonitorForEvents([.leftMouseDown,.rightMouseDown])` + 로컬 keyDown 모니터(Esc, keyCode 53).
- 팝업 표시 여부로 갱신 게이팅(`setInterfaceActive` 패턴) — 위젯 스케줄러의 "보일 때만 고빈도 갱신" 정책과 직결.

M1에서 **비활성화 NSPanel(`.nonactivatingPanel`)로 전환 검토**: 화살표 없는 사각 팝업, 포커스 탈취 없는 키 입력(Raycast 스타일), 스와이프 제스처 충돌 최소화가 필요해지는 시점. NSPopover의 화살표/암시적 애니메이션은 페이지네이션 UI와 미학적으로 충돌한다. 전환 비용을 낮추기 위해 팝업 컨트롤러를 프로토콜(`PopupSurface`)로 추상화한다.

### 1.4 스크립트 실행 계층: 옵션 비교와 추천

| 옵션 | 장점 | 단점 | 판정 |
|---|---|---|---|
| **서브프로세스** (xbar/SwiftBar 방식) | 언어 무제한, 프로세스 격리 공짜, 기존 CLI(otpeek/aas) 즉시 활용, 크래시가 호스트에 무해 | 콜드스타트 비용(otpeek은 vault 복호화 KDF로 수십~수백ms), 상태 유지 불가, MAS 샌드박스에서 임의 실행 불가 | **Tier 1 채택** — 데이터소스 계층 |
| **JavaScriptCore 임베디드** | 시스템 프레임워크(배포 용량 0, MAS 허용), 위젯별 독립 `JSContext`, 동기 이벤트 핸들러 가능, TS→JS 트랜스파일로 TS DSL 지원 | 언어가 JS로 고정, OS API는 호스트가 브리지한 것만 | **Tier 2 채택** — 인터랙션/변환 로직 |
| Lua 임베디드 (Hammerspoon 방식) | 초경량, 임베딩 용이 | 생태계·타입 지원 약함, JSC 대비 이점 없음, 런타임 번들 필요 | 보류 |
| Python 서브프로세스 상주(데몬) | 풍부한 생태계 | 인터프리터 배포/버전 지옥, 메모리 상주 비용, 격리 어려움 | 배제 (서브프로세스 Tier 1으로 py 스크립트는 이미 커버됨) |

**추천: 2계층 하이브리드.**
- **Tier 1 (exec provider)**: manifest에 선언된 커맨드를 스케줄에 따라 실행, stdout JSON을 뷰 트리 또는 원시 데이터로 수용. 어떤 언어로 짜든 상관없음. 타임아웃(기본 10s)·출력 크기 제한(1MB)·연속 실패 백오프를 호스트가 강제.
- **Tier 2 (JS provider)**: `widget.js`를 위젯별 `JSContext`에 로드. `render(data, state)`(뷰 트리 반환), `onAction(id, payload, state)`(이벤트 처리) 훅 제공. 호스트 브리지 API는 화이트리스트(`mb.exec`, `mb.state`, `mb.http` — 각각 manifest 권한 필요).
- 단순 위젯은 Tier 1만으로 완결(스크립트가 뷰 트리를 직접 출력), 복잡한 위젯은 Tier 1을 데이터소스로 쓰고 Tier 2에서 렌더/이벤트를 담당.

### 1.5 렌더링 계층: JSON 뷰 트리 → SwiftUI

- 노드 타입 v0.1: `vstack / hstack / grid / list / text / label(sf-symbol) / image / progress / gauge / spacer / divider / button / menu / countdown`.
  - `countdown`은 OTP처럼 **마감시각(deadline) 기반 자체 갱신** 노드 — 스크립트 재실행 없이 호스트가 틱을 그린다(OTPeek의 `CountdownRing`/`OTPTick`과 동일 발상).
- 각 노드는 `type`, `props`, `children`, 그리고 인터랙티브 노드는 `action`(액션 ID + payload)을 가진다.
- 스키마는 `schemaVersion` 필드로 버전드. 알 수 없는 노드 타입은 placeholder로 그리고 경고 배지(전방 호환).
- SwiftUI 매핑은 `MenubucketCore`의 Codable 모델 → `MenubucketApp`의 `ViewTreeRenderer`(recursive `@ViewBuilder`). AppKit이 필요한 부분(파일 그리드, 드래그아웃)은 Stashbar의 `NSViewRepresentable` 브리징 패턴(`IconCollectionViewRepresentable`의 coordinator + generation counter)을 이식한다.
- diff/애니메이션: 뷰 트리에 안정적 `id`를 요구하고 SwiftUI의 identity 기반 트랜지션에 위임(자체 diff 엔진은 만들지 않는다).

---

## 2. 위젯 모델

### 2.1 Manifest — JSON 추천 (`widget.json`)

포맷 비교: YAML(오타 관대함이 오히려 독), TS DSL(빌드 스텝 필요 — M3에서 JSON으로 컴파일되는 상위 계층으로 제공). **JSON 채택** 근거: Swift `Codable` 직결, JSON Schema 검증, TS DSL의 컴파일 타깃으로 재사용.

```jsonc
{
  "$schema": "https://menubucket.dev/schema/widget-0.1.json",
  "id": "dev.menubucket.aas-usage",
  "name": "LLM 사용량",
  "version": "0.1.0",
  "icon": "gauge",                      // SF Symbol
  "page": { "group": "dev", "order": 2 }, // 팝업 내 페이지 배치

  "source": {                          // Tier 1: 데이터소스
    "kind": "exec",
    "command": ["aas", "usage", "--json"],
    "discover": ["$AAS_BIN", "~/.cargo/bin/aas", "/opt/homebrew/bin/aas"],
    "timeoutMs": 15000,
    "output": "data"                   // "data" = 원시 JSON, "viewtree" = 즉시 렌더
  },

  "logic": "widget.js",                // Tier 2 (선택): render()/onAction()

  "refresh": {
    "interval": 180,                   // 초. 팝업 열림 중엔 visibleInterval 적용 가능
    "onOpen": true,                    // 팝업 열릴 때 즉시 1회
    "deadlineField": null,             // 출력 JSON의 epoch-ms 필드를 다음 갱신 시각으로
    "watchPaths": []                   // FSEvents 트리거 (파일 위젯용)
  },

  "permissions": {                     // §4 권한 모델
    "exec": ["aas"],
    "network": false,
    "env": ["AAS_BIN"],
    "readPaths": [], "keychain": false
  },

  "state": { "persist": true }         // 위젯별 KV 지속화 여부
}
```

### 2.2 데이터 갱신 주기

스케줄러는 위젯당 하나의 갱신 파이프라인을 소유하며 트리거 4종을 지원:
1. **interval** — 최소 5초, 팝업 닫힘 상태에선 `hiddenMultiplier`(기본 4x)로 완화. 상태바 텍스트를 쓰는 위젯만 닫힘 중에도 갱신.
2. **deadline** — 출력 JSON이 지정한 epoch-ms(예: otpeek의 `validUntil`)에 맞춰 정확히 재실행. 폴링 낭비 제거.
3. **watch** — Stashbar의 `DirectoryWatcher`(FSEventStream, 0.1s latency, WatchRoot) 이식. 파일 위젯의 기본 트리거.
4. **onOpen / manual** — 팝업 열림, 사용자 새로고침.

공통 정책: 실행 중복 방지(in-flight coalescing — Stashbar `ThumbnailCache`의 inFlight 패턴 재사용), 연속 실패 시 지수 백오프, **마지막 성공 결과 유지**(aas-bar 설계 문서의 "UI never blanks" 원칙 채택).

### 2.3 이벤트 처리

- **클릭/버튼**: 뷰 노드의 `action: {id, payload}` → 디스패처가 (a) `logic`의 `onAction(id, payload, state)` 호출, 또는 (b) manifest의 선언적 액션(`{"run": ["aas","switch","{payload}"]}`, `{"open": "url"}`, `{"copy": "{text}"}`, `{"refresh": true}`) 실행. OTP "클릭=복사", aas "클릭=계정 전환"이 선언만으로 가능해야 한다.
- **키보드**: 팝업 포커스 시 방향키/⌘1..9(페이지 점프), Esc 닫기(Stashbar 로컬 모니터 방식), 위젯이 `keyable: true`면 나머지 키를 위젯 액션으로 전달.
- **스와이프/페이지네이션**: 팝업 콘텐츠는 `TabView(.page)` 유사 커스텀 페이저(트랙패드 수평 스크롤 + 하단 도트 인디케이터). 페이지 = manifest의 `page.group` 단위. 한 페이지에 위젯 여러 개(세로 스택)도 허용.

### 2.4 상태 관리

- **호스트 소유 KV 스토어**: `~/Library/Application Support/menubucket/state/<widget-id>.json`. 스크립트는 스냅샷을 받고 패치를 반환(직접 파일 접근 금지) — 위젯 격리와 디버깅 용이성 확보.
- 파생 상태(카운트다운 진행률 등)는 저장하지 않고 렌더 시 계산(OTPeek의 "no persisted rotation" 원칙).
- 위젯 소스 변경 감지 시 hot reload(위젯 디렉토리를 FSEvents로 감시 — 개발 경험 핵심).

---

## 3. 기존 앱 통합 시나리오 (구체적 API 계약)

### 3.1 OTP 위젯 ← otpeek CLI

조사 결과 (`core/crates/otpeek-cli/src/main.rs`):
- `otpeek list --json` → `OtpAccount[]` (issuer, accountName, period 등). `otpeek code <query> --json` → `{"code":"123456","validFrom":<ms>,"validUntil":<ms>}`. 쿼리는 1-based 인덱스 또는 fuzzy 매칭(모호 시 exit 2).
- **인증 제약**: vault는 패스워드 암호화. 헤드리스는 `OTPEEK_VAULT_PASSWORD` 환경변수 필수. macOS 앱의 vault는 App Group(`group.com.otpeek.app`) 컨테이너 + Keychain VMK인데, **서드파티는 접근 불가(same-team signing)** → menubucket은 자체 vault 경로(`$OTPEEK_VAULT`)를 쓴다.
- **레이턴시**: 매 호출이 콜드스타트 + Argon2급 KDF 복호화 → 수십~수백ms. 남발 금지.

위젯 설계:
- `refresh.deadlineField: "validUntil"` — 코드 만료 시각에 정확히 1회 재실행. `countdown` 노드가 사이 틱을 자체 렌더.
- 패스워드는 **menubucket이 자기 Keychain 항목으로 보관**하고 환경변수로 주입 (manifest `permissions.keychain: true` + `env: ["OTPEEK_VAULT_PASSWORD"]`). 평문 manifest 저장 금지.
- otpeek 측 개선 제안(upstream PR 후보): ① `--stdin-password` 옵션(env는 `ps`엔 안 보여도 자식 상속 위험), ② `code --all --json`(계정 N개를 1회 KDF로 일괄 조회 — N회 복호화 제거), ③ 장기적으로 `otpeek serve`(로컬 소켓) 데몬.

### 3.2 사용량 위젯 ← aas CLI

조사 결과 (`crates/aas-cli/src/main.rs:90-97, 340-368`): **`aas usage --json`이 이미 "aas-bar 등 통합용"으로 존재.** 스키마:
```json
{"accounts":[{"provider":"...","name":"...","email":"...","active":true,
  "plan":"...","planLabel":"...","headline":"...","error":null,
  "meters":[{"label":"5h","usedPct":42.0,"resetMs":1751900000000}]}]}
```
계약 그대로 채택할 사항 (aas의 `docs/DESIGN-aas-bar.md` 설계를 menubucket 위젯으로 흡수):
- 바이너리 탐색: `$AAS_BIN` → `~/.cargo/bin/aas` → homebrew → PATH (GUI 앱은 최소 PATH — manifest `discover` 필드가 이걸 일반화).
- 폴링 180s, 마지막 성공 결과 유지, in-flight 병합.
- 헬스 매핑: `remaining = 100 − usedPct`, 미터 중 최악값으로 red(<10)/amber(10–30)/green(≥30), `error` 존재 시 red. `planLabel` null이면 `headline` 폴백.
- CLI가 **429 백오프를 디스크에 지속**(`usage-backoff.json`)하므로 호스트가 재시도 폭주해도 API를 안 때림 — 서브프로세스 데이터소스의 모범 사례. **필요한 추가 작업 없음.**
- 액션 계약: 계정 행 클릭 → `aas switch <provider>/<name>` 실행 후 refresh (`permissions.exec: ["aas"]`).

### 3.3 파일 위젯 ← file-stack 스타일 (내장 네이티브 위젯)

파일 스태시는 CLI 계약으로 풀 수 없다(드래그&드롭 아웃, QuickLook, 썸네일 = 프로세스 경계 밖 불가). **호스트 내장 위젯 타입 `kind: "builtin/filestack"`으로 제공**하고 Stashbar 코드를 이식:
- `DirectoryWatcher`(FSEvents 래퍼) → 스케줄러의 watch 트리거로 승격.
- 3단 캐시(`ThumbnailCache` NSCache 200개/64MB + QLThumbnailGenerator, `DiskThumbnailCache` sha256 키/mtime 스탬프/200MB LRU, `FileIconCache`) 통째로 이식.
- 드래그아웃: `NSCollectionView pasteboardWriterForItemAt` / SwiftUI `.onDrag { NSItemProvider(object: url as NSURL) }`.
- 폴더 접근: NSOpenPanel + security-scoped bookmark(`WatchedFolderBookmarks_v1` 패턴) — 샌드박스 호환.
- 교훈: **"builtin 위젯" 개념 자체가 아키텍처 요구사항.** 뷰 트리로 표현 불가한 위젯을 위해 네이티브 플러그인 슬롯을 처음부터 설계에 포함하되, builtin도 동일한 페이지/스케줄러/권한 프레임에 태운다.

---

## 4. 보안 / 샌드박싱

### 4.1 권한 모델

- **선언 → 승인 → 강제** 3단계: manifest `permissions`가 요구를 선언, 설치 시 사용자가 승인(diff UI: "이 위젯은 `aas` 실행과 Keychain 1항목을 요구합니다"), 런타임이 강제.
  - `exec`: 실행 가능 바이너리 allowlist (베이스네임 + 해석된 절대경로 기록). allowlist 밖 exec 시도는 차단+로그.
  - `network`: Tier 2 `mb.http`에만 적용 (Tier 1 서브프로세스의 네트워크는 OS 수준에서 못 막음 — 문서에 명시하고 exec allowlist로 신뢰 경계를 형성).
  - `env` / `readPaths` / `keychain`: 주입할 환경변수, 읽기 경로, menubucket 네임스페이스 Keychain 접근.
- Tier 2(JSC)는 기본 무권한: 브리지에 노출된 API 외에는 파일/네트워크/프로세스 접근 자체가 불가능 — 임베디드 인터프리터의 본질적 이점.
- 위젯 서명/출처: M3에서 위젯 디렉토리 해시 매니페스트 + 설치 출처 기록(공유 생태계 전 단계).

### 4.2 App Store 배포 가능성 판단

- Stashbar 증거: `scripts/FileStack.entitlements` = `app-sandbox` + `user-selected.read-write`, `AppStore/`는 MAS 메타데이터/스크린샷 — **파일 위젯류(builtin)는 MAS 통과 가능**이 실증됨.
- 그러나 menubucket의 핵심인 **임의 사용자 스크립트/CLI 실행은 샌드박스와 충돌**: 샌드박스 앱이 사용자 실행파일을 돌리는 유일한 정규 경로는 `~/Library/Application Scripts/<bundle-id>/`의 `NSUserUnixTask`(SwiftBar MAS 버전이 실제 이 방식). PATH 상 임의 바이너리(`~/.cargo/bin/aas`) 직접 exec은 불가.
- **판정: Developer ID(공증) 배포를 1급 시민으로.** MAS는 M3에서 "라이트 에디션"(builtin 위젯 + Application Scripts 폴더 경유 스크립트 + JSC 위젯만)으로 분기 검토. 코드베이스는 처음부터 `SANDBOXED` 빌드 플래그로 exec 경로를 추상화해 두 배포본이 소스를 공유하게 한다.
- 공통 하드닝: Hardened Runtime + 공증, 스크립트 stdout 크기 제한, 위젯별 프로세스 그룹으로 좀비 정리, 로그에 비밀값 마스킹.

---

## 5. 선행 사례 비교

| 사례 | 취할 것 | 버릴 것 |
|---|---|---|
| **xbar** | "플러그인 = 실행파일 하나" 진입장벽, 파일명에 갱신주기 인코딩하는 발상(우리는 manifest로 정식화), stdout 프로토콜 | 텍스트 라인 기반 포맷의 표현력 한계, NSMenu 전용 UI, 파라미터 파싱의 취약함 |
| **SwiftBar** | 스트리밍 플러그인(장수 프로세스) 개념, MAS/비MAS 이중 배포 전략, SF Symbol 지원 | 여전히 메뉴 기반 UI, 플러그인 메타데이터가 주석에 숨는 방식 |
| **Übersicht** | 웹기술 수준의 렌더 자유도 목표치, **hot reload 개발 루프**, `run()` 커맨드 브리지 | WKWebView 위젯당 메모리 비용, 데스크톱 오버레이 한정(메뉴바 아님), CoffeeScript 시대 잔재 |
| **Hammerspoon** | 임베디드 단일 런타임(우리의 JSC Tier 2에 해당), 이벤트 훅 설계(pathwatcher ≈ 우리의 watch 트리거) | 전권 실행 모델(권한 경계 부재 — 우리 권한 모델의 반면교사), UI 프리미티브 부족으로 canvas에 직접 그리기 |
| **Raycast extensions** | **React 선언 UI → 네이티브 렌더**(우리 뷰 트리의 원형), TS 타입 패키지로서의 SDK, 스토어 심사 모델 | Node 상주 런타임의 무게, 폐쇄 소스 렌더러, 플랫폼 종속 배포 |
| **iOS Shortcuts / WidgetKit** | 타임라인/deadline 기반 갱신 예산(우리의 deadline 트리거), 선언적 액션 조합(우리의 manifest 액션 `run/open/copy`) | 표현력 상한이 낮은 노코드 편집기(우리는 코드 우선), 상호작용 제약 |

종합: **"xbar의 배포 단순함 × Raycast의 렌더 품질 × WidgetKit의 갱신 규율 × 명시적 권한 모델"**이 menubucket의 차별화 축.

---

## 6. 단계별 로드맵

### M0 — PoC (2주)
- 산출물: SwiftPM 앱 골격(Stashbar `main.swift` 팝업 코드 + `build_app.sh` 이식), `MenubucketCore` 뷰 트리 Codable 모델 + `ViewTreeRenderer`(text/stack/progress/gauge/button), exec provider(고정 커맨드), **aas 사용량 위젯 1개 하드코딩**.
- 검증 기준: 메뉴바 클릭 → 팝업에 aas 계정별 미터가 네이티브 렌더링, 180s 폴링 + 수동 새로고침 동작, `aas` 부재/오류 시 마지막 성공 상태 + 오류 배지 유지, 콜드 부팅 CPU/메모리 프로파일(상주 < 50MB).

### M1 — 위젯 플랫폼 코어 (4주)
- 산출물: `widget.json` manifest v0.1 + JSON Schema + 로더(디렉토리 스캔 `~/Library/Application Support/menubucket/widgets/`), 스케줄러 4트리거(interval/deadline/watch/onOpen), 선언적 액션(run/open/copy/refresh), 페이지네이션(스와이프+도트+⌘숫자), **otpeek 위젯**(deadlineField=validUntil, countdown 노드, Keychain 경유 패스워드 주입), hot reload.
- 검증 기준: 위젯 3개(aas/otpeek/시계 예제)가 manifest만으로 설치·페이지 전환, OTP가 만료 시각에 정확히 1회 재실행되고 클릭 시 클립보드 복사, 위젯 스크립트 크래시가 다른 페이지에 무영향, manifest 스키마 위반 시 명확한 설치 오류.

### M2 — 스크립팅/보안 심화 (5주)
- 산출물: JavaScriptCore Tier 2(`render`/`onAction` 훅, `mb.exec/state/http` 브리지), 권한 모델 강제(exec allowlist, 승인 UI, 감사 로그), 상태 스토어(스냅샷/패치), **builtin filestack 위젯**(DirectoryWatcher + 3단 썸네일 캐시 + 드래그아웃 이식), 키보드 네비게이션.
- 검증 기준: 권한 미승인 exec 차단 확인 테스트, JS 위젯이 버튼 이벤트로 상태를 갱신하고 재시작 후 복원, 파일 위젯에서 Finder로 드래그아웃 성공, 위젯 10개 동시 구동 시 배터리 영향 측정(Activity Monitor Energy < "Low").

### M3 — 배포/생태계 (5주+)
- 산출물: Developer ID 서명 + 공증 + Sparkle 자동업데이트, TS DSL SDK(`@menubucket/sdk` — JSX/함수형 API가 widget.json+widget.js로 컴파일) + 예제 갤러리, 위젯 설치 UX(폴더 드롭/URL), MAS 라이트 에디션 타당성 스파이크(NSUserUnixTask 경유 exec + `SANDBOXED` 플래그 빌드), otpeek upstream 개선 PR(`--stdin-password`, `code --all --json`).
- 검증 기준: 외부 개발자 1인이 문서만으로 신규 위젯을 30분 내 작성, 공증 배포본이 클린 macOS에서 Gatekeeper 통과, MAS 스파이크 결과 go/no-go 문서화.

---

## 7. 열린 질문 (다음 라운드)

1. 상태바 아이콘 자체의 위젯화(텍스트/미니 게이지 표시) 범위 — NSStatusItem 다중 생성 허용 여부.
2. 뷰 트리 스키마의 스타일 시스템(토큰 기반 vs 자유 속성) — 다크모드/시스템 액센트 대응.
3. otpeek처럼 비밀을 다루는 위젯의 클립보드 자동 소거(NSPasteboard expiry) 표준화.
4. 위젯 간 데이터 공유(예: aas 활성 계정을 다른 위젯이 구독) 허용 여부 — 초기엔 금지 권장.
