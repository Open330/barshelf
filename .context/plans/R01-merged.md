# menubucket — R01 통합 기획서 (merged)

- 작성일: 2026-07-08
- 소스: `R01-claude.md`(아키텍처/코드베이스 통합), `R01-codex.md`(기술 스펙), `R01-claude-ux.md`(제품/UX)
- 지위: **이 문서가 이후 구현의 캐노니컬 스펙.** 세부 스키마·예제는 각 R01 문서를 참조.

---

## 0. 전원 일치 합의사항

| 항목 | 합의 내용 | 출처 |
|---|---|---|
| 호스트 | Swift/AppKit — `NSStatusItem + NSPopover + NSHostingController`, SwiftPM executable (Stashbar `main.swift` 패턴 + `build_app.sh` 이식) | 3/3 |
| UI 정의 | WebView 배제. **선언형 JSON 뷰 트리(`UINode`) → SwiftUI 네이티브 렌더링** (server-driven UI). diff/접근성/카운트다운 틱은 호스트 책임 | 3/3 |
| 스크립트 실행 | **서브프로세스 격리가 기본.** 기존 CLI(otpeek/aas)가 데이터소스. 크래시가 호스트에 무해 | 3/3 |
| 그룹화 | **Bucket = 페이지.** 버킷 내부 세로 스크롤, 버킷 간 가로 스와이프로 축 분리. 도트 + ⌘1..9 + ←/→ | 3/3 |
| 갱신 규율 | stale-while-revalidate — 마지막 성공 렌더 유지("UI never blanks"), 실패 시 배너, in-flight coalescing, 지수 백오프. 팝업 닫힘 중 틱/프리페치 중단 | 3/3 |
| 권한 모델 | manifest **선언 → 설치 시 승인(diff UI) → 런타임 강제**. exec allowlist(정확한 바이너리+args 패턴), no shell, 출력 크기 제한 | 3/3 |
| 파일 위젯 | CLI로 불가(드래그아웃/QuickLook/썸네일). **builtin 네이티브 위젯**으로 Stashbar 코드(DirectoryWatcher, 3단 썸네일 캐시) 이식 | 3/3 |
| 배포 | **Developer ID 공증이 1급.** App Store는 임의 exec와 구조적 충돌 → M3에서 "라이트 에디션"(workflow-only) 스파이크만 | 3/3 |
| otpeek 통합 | `code --json`의 `validUntil` 기반 deadline 갱신 + countdown 노드 자체 틱. 현 `list --json`은 secret 포함 → sensitive 취급 + upstream에 `--public-json`/`code --all --json`/`--stdin-password` PR | 2/3 (UX 무관) |
| aas 통합 | `aas usage --json`이 이미 통합용 계약. 바이너리 탐색(`$AAS_BIN`→cargo→brew→PATH), CLI 자체의 디스크 백오프 존중. 추가 작업 불필요 | 2/3 |

## 1. 충돌 조정 (결정 사항)

### D1. 스크립트 런타임: 임베디드 JSC vs Deno 서브프로세스 → **서브프로세스 단일 경계 (Codex 안 채택, 단계 조정)**

- Claude 안: Tier 1 서브프로세스 + Tier 2 임베디드 JavaScriptCore(인터랙션 로직).
- Codex 안: 제3자 코드를 앱 프로세스 안에서 실행하지 않는 것이 핵심 보안 경계 — JSC 배제, Deno 서브프로세스 + JSON-RPC.
- **결정**: **프로세스 격리를 유일한 신뢰 경계로 유지** — 임베디드 JSC로 서드파티 위젯 코드를 돌리지 않는다. 인터랙션 로직이 필요한 위젯은 M2의 Deno(JSON-RPC over stdio, `--deny-net --deny-run --deny-write`) 러너를 쓴다. 단, Deno는 외부 의존성이므로 **호스트는 Deno 없이도 완전 동작**해야 한다(아래 실행 계층 3층 구조). Python/Lua 러너는 프로토콜만 고정하고 v1.1로.
- JSC의 잔여 용도: 서드파티 코드가 아닌 **workflow 표현식 평가는 자체 미니 evaluator**(JSONPath + 내장 함수, arbitrary JS 아님)로 — JSC조차 불필요.

### D2. 실행 계층 최종 구조 — 3층

```
Layer 0  builtin  : 호스트 내장 네이티브 위젯 (filestack). 페이지/스케줄러/권한 프레임은 동일하게 적용
Layer 1  exec     : manifest 선언만으로 커맨드 실행 → stdout JSON을
                    (a) output=viewtree  : UINode 트리로 즉시 렌더 (xbar의 정신적 후계)
                    (b) output=data     : 원시 데이터 → workflow(M2) 또는 builtin adapter(M0)가 뷰로 변환
Layer 2  script   : 상주 서브프로세스 + JSON-RPC (Deno TS 1급, M2). render/action/timer 훅, mb.* API는 전부 호스트 경유
```

### D3. Manifest 포맷: JSON vs YAML → **JSON (`widget.json`)**

- 근거: Swift `Codable` 직결(외부 의존성 0), JSON Schema 검증, M3 TS DSL의 컴파일 타깃으로 재사용. Codex의 YAML 스키마 내용(권한 상세, bucket, statusItem, settings)은 **필드 구조 그대로 JSON으로 수용**. YAML 지원은 필요 시 후순위.

### D4. 갱신 기본값: 폴링 vs 캐시 우선 → **캐시 우선 (Codex 안)**

- 기본: `interval: null` + `onOpen: true` + `staleAfter` + 수동 새로고침. interval은 옵트인(최소 5s 전경/60s 배경). aas 위젯 기본은 staleAfter 10–15분(레이트리밋 존중). deadline(`deadlineField`)·watch(FSEvents)·wake 트리거는 Claude 안대로 유지.

### D5. 팝업 표면: NSPopover vs NSPanel → **`PopupSurface` 프로토콜로 추상화, M0=NSPopover, M1에서 비활성화 NSPanel 전환 검토** (Claude 안)

- 화살표 없는 사각 팝업 + 포커스 비탈취 키 입력 + 스와이프 충돌 최소화가 필요해지는 시점에 전환. 전환 비용은 프로토콜이 흡수.

### D6. UX 구조 통합 (UX 안 ↔ Codex layout 매핑)

- 사이즈 클래스: **XS**(메뉴바 인라인 텍스트/배지) / **S**(타일, 2열 그리드 반폭) / **M**(카드, 전폭) / **L**(패널, 페이지 단독) — Codex `page: compact`=S·M 혼합 페이지, `page: full`=L.
- 팝업 골격: 헤더(호버 시) → 📌 핀 행(모든 페이지 상단 상주, 최대 2행, M2) → Bucket 페이지 영역 → 하단 바(도트·검색 ⌘F(M2)·설정·편집).
- 키보드 퍼스트: ⌘1..9 버킷 점프, ←/→ 버킷 전환, ↑/↓ 포커스, ⏎ primary action, ⌘R/⌘⇧R 새로고침, Esc 단계적 닫기, 글로벌 핫키(기본 ⌥Space).
- 온보딩: CLI 의존성 없는 스타터 위젯으로 시작(빈 팝업 금지), CLI 위젯은 의존성 감지 + 원클릭 설치 안내.

### D7. 수익화/배포 (UX 안 채택)

- 오픈코어(엔진/렌더러/포맷 스펙 오픈소스) + **Pro $29 일시불 직접 판매**(구독 회피). Homebrew cask + 자체 사이트. 어휘: 그룹=**Bucket**, CLI=`mbk`.

## 2. 최종 아키텍처

```
MenuBucket.app (LSUIElement)
├─ AppKitHost        StatusItemController · PopupSurface(NSPopover→NSPanel) · GlobalEventMonitor
├─ NativeRenderer    UINodeDecoder · SwiftUIRenderer(+AppKit bridge) · ActionRouter
├─ WidgetRuntime     WidgetCatalog(manifest 로더) · Scheduler(open/interval/deadline/watch/manual/wake)
│                    · RuntimeSupervisor(M2, JSON-RPC) · WorkflowEngine(M2) · PermissionStore
├─ DataServices      ExecService(경로해석·타임아웃·출력제한·no-shell) · HttpService(M2)
│                    · StorageService · SecretStore(Keychain) · FileSource+ThumbnailService(M2, Stashbar 이식)
└─ Persistence       InstalledWidgetDB · 렌더 스냅샷 캐시 · 위젯별 로그(1MB rotate, redaction)
```

패키지: `Sources/MenubucketCore`(UINode·manifest·스케줄 정책 — UI 무의존, 테스트 대상) / `Sources/MenubucketApp`(셸+렌더러+런타임) / `Tests/`, `widgets/`(예제), `scripts/`(build_app.sh 이식).

핵심 불변식:
1. 스크립트/CLI 프로세스는 직접 network/spawn/write 권한 없음 — 모든 I/O는 호스트 API 경유(Layer 2) 또는 exec allowlist(Layer 1).
2. 마지막 정상 렌더 스냅샷은 항상 캐시되고, 실패는 배너로만 표현된다.
3. 팝업이 닫혀 있으면 UI 틱·썸네일 프리페치 중단, 배경 갱신은 `runInBackground` 위젯만.
4. 뷰 트리의 반복 노드는 안정적 `id` 필수 — SwiftUI identity와 액션 라우팅에 사용.
5. 크래시 루프(5분 내 3회) → `disabled` 전환, 스냅샷 유지, "Restart Widget" CTA.

## 3. Manifest v0.1 (통합 스키마, JSON)

```jsonc
{
  "$schema": "https://menubucket.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.menubucket.aas-usage",
  "name": "aas Usage",
  "version": "0.1.0",
  "icon": "gauge",
  "bucket": { "group": "Agents", "order": 20, "size": "M" },   // XS|S|M|L

  "entry": { "kind": "exec" },          // exec | script | workflow | builtin
  "source": {                            // entry.kind=exec 일 때
    "kind": "exec",
    "command": ["aas", "usage", "--json"],
    "discover": ["$AAS_BIN", "~/.cargo/bin/aas", "/opt/homebrew/bin/aas", "/usr/local/bin/aas", "PATH"],
    "timeoutMs": 25000,
    "output": "data",                    // "viewtree" | "data"
    "adapter": "aas-usage"               // output=data일 때 builtin adapter (M2에서 workflow로 대체 가능)
  },

  "refresh": { "onOpen": true, "interval": null, "staleAfterSec": 600,
               "deadlineField": null, "watchPaths": [], "runInBackground": false },

  "statusItem": { "mode": "none" },      // none | icon | text | dynamic (XS 승격)

  "permissions": {
    "exec": [{ "command": "aas", "allowedArgs": [["usage", "--json"]],
               "maxOutputBytes": 1048576, "sensitiveOutput": false }],
    "network": [], "readPaths": [], "env": ["AAS_BIN"], "keychain": false
  },

  "settings": []                         // 위젯 설정 UI 자동 생성 (M1)
}
```

UINode v0.1 노드: `vstack hstack list grid section text image(sfSymbol|fileIcon|fileThumbnail) progress(linear|ring, countdown value) button badge banner empty divider spacer switch` — 필드 상세와 SwiftUI 매핑은 `R01-codex.md §7`, countdown 자체 틱은 호스트 `TimelineView`. 알 수 없는 타입은 placeholder + 경고(전방 호환).

액션: `event`(script로 전달) · `copyText`(+toast) · `openURL` · `openFile` · `revealFile` · `run`(allowlist 내 exec 후 refresh) · `refresh`.

## 4. 통합 로드맵

| 마일스톤 | 산출물 | 검증 기준 |
|---|---|---|
| **M0 · PoC (지금)** | SwiftPM 골격(팝업+상태아이템), `MenubucketCore` UINode 모델+렌더러 v0(text/stack/list/progress/button/badge/banner/empty/image-sfSymbol), ExecService(탐색·타임아웃·출력제한), manifest 로더 최소판, **aas 위젯(data+adapter)** + **hello 위젯(output=viewtree 셸 스크립트)**, 페이지 전환(도트+←/→+⌘숫자), last-good-render, 우클릭 메뉴 | 메뉴바 클릭→팝업에 aas 미터 네이티브 렌더, `aas` 부재 시 오류 배너+캐시 유지, viewtree 위젯이 manifest만으로 로드, `swift test` 통과, 상주 메모리 <50MB |
| **M1 · 플랫폼 코어 (4주)** | manifest v0.1 전체+JSON Schema, 스케줄러 4트리거(deadline/watch 포함), 선언적 액션 전체, 트랙패드 스와이프 페이저, **otpeek 위젯**(deadline+countdown+Keychain 패스워드 주입+클릭 복사), hot reload, NSPanel 전환 검토 | OTP가 만료 시각에 정확히 1회 재실행·클릭 복사, 위젯 크래시가 타 페이지 무영향, 스키마 위반 시 명확한 오류 |
| **M2 · 스크립팅/보안 (5주)** | Deno JSON-RPC 러너+`menubucket` TS SDK(`mb.exec/http/storage/secret/notify/timer`), 권한 승인 UI+감사 로그, workflow 엔진 v1(fs.directory 포함), **builtin filestack**(썸네일 3단 캐시+드래그아웃), 핀 행, 통합 검색(⌘F), 설정 UI | 미승인 exec 차단 테스트, JS 위젯 상태 재시작 복원, Finder 드래그아웃, 위젯 10개 동시 에너지 "Low" |
| **M3 · 배포/생태계 (5주+)** | 공증+Sparkle, `mbk` CLI(install/new/dev/validate/pack), `.mbw` 패키징+서명, 갤러리+원라인 설치, TS DSL SDK, MAS 라이트 스파이크, otpeek upstream PR | 외부 개발자가 문서만으로 30분 내 위젯 작성, 클린 macOS Gatekeeper 통과 |

## 5. 열린 질문 (R02 후보)

1. XS(메뉴바 인라인) 다중 표시 정책 — NSStatusItem 추가 생성 허용 범위 (Pro 기능 후보)
2. 위젯 간 데이터 공유(aas 활성 계정 → 타 위젯 구독) — 초기 금지 권장, 프로토콜만 예약
3. workflow 표현식: 자체 evaluator(JSONPath+내장함수) vs CEL 도입
4. 클립보드 자동 소거(NSPasteboard expiry) 표준화 — OTP류 sensitive 액션 공통 정책
5. registry 운영 시점 — v1은 local/GitHub install만
