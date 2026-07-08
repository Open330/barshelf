# menubucket M2-a 구현 태스크 (R03) — 스크립트 런타임 (Deno JSON-RPC) + 권한 강제

전제: M1 완료(테스트 50/50). 스펙: `.context/plans/R01-merged.md` §1 D1·D2, `.context/plans/R01-codex.md` §5·§6(프로토콜 원문). 구조: `.context/impl/R02-claude.md`.
주의: **이 머신에 deno 미설치.** 호스트는 deno 없이 완전 동작해야 하며(위젯은 오류 카드), 테스트는 스텁 러너로 프로토콜을 검증한다. 테스트 실행: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## 공통 계약 — JSON-RPC 프로토콜 v1 (두 에이전트 일치 필수)

전송: **newline-delimited JSON-RPC 2.0 over stdio** (한 줄 = 한 메시지).

### Host → Script (notifications)
| method | params |
|---|---|
| `widget.load` | `{widgetId, reason: "install"\|"open"\|"manual"\|"timer"\|"interval", now, locale, appearance: "light"\|"dark", settings, lastRenderRevision}` |
| `widget.action` | `{actionId, payload, now}` |
| `widget.timer` | `{id, now}` |

### Script → Host (requests, id 필수 / host가 result 또는 error 응답)
| method | params → result |
|---|---|
| `host.render` | `{root: UINode, status?: {label?, tooltip?}, nextRefreshAt?, cacheTtlMs?, sensitive?}` → `{revision}` |
| `host.exec.run` | `{command, args, parse?: "text"\|"json"\|"lines", timeoutMs?, sensitive?, env?}` → `{exitCode, stdout, stderr, json?, durationMs}` — manifest permissions.exec allowlist 강제 |
| `host.storage.get/set/delete/list` | `{key, value?, prefix?}` → 값/키 목록. 위젯별 네임스페이스, quota 1MB |
| `host.secret.get/set` | `{key, value?}` — Keychain(`dev.menubucket` service, `<widgetId>/<key>` account). manifest `permissions.keychain: true` 필요 |
| `host.timer.once/after/every/clear` | `{id, atMs?/delayMs?/intervalMs?}` — 호스트 Scheduler 등록, `minInterval` 강제 |
| `host.notify.show` | `{title, body?}` — manifest `permissions.notifications: true` 필요 |
| `host.log` | `{level: "debug"\|"info"\|"warn"\|"error", message}` → 위젯 로그 파일 |

오류 코드: `-32001 PermissionDenied`, `-32002 ExecNotFound`, `-32003 Timeout`, `-32004 QuotaExceeded`, `-32005 ProtocolError`.

### Deno 실행 커맨드 (host가 조립)
```
deno run --quiet --no-prompt --no-remote \
  --allow-read=<widget-bundle-dir> \
  --import-map=<generated-import-map.json> \   # {"imports": {"menubucket": "file://<sdk>/mod.ts"}}
  <bundle>/index.ts
```
deno 탐색: `$DENO_BIN` → `/opt/homebrew/bin/deno` → `/usr/local/bin/deno` → `~/.deno/bin/deno` → PATH. SDK 위치: 개발 모드 `./sdk/mod.ts`(cwd), 번들 모드 앱 리소스.

### 라이프사이클
- 위젯당 상주 프로세스 1개. refresh 트리거 시 살아있으면 `widget.load` notification 재전송, 죽었으면 재기동.
- stdout 라인 1MB 제한, stderr는 위젯 로그로 스트림. 응답 없는 요청 타임아웃 20s.
- 크래시 루프: 5분 내 3회 → `disabled` 상태 + 스냅샷 유지 + "Restart Widget" 액션 (R01-codex §9.3).

## Task A — 호스트 측 (담당: Claude 에이전트)

**소유**: `Package.swift`, `Sources/**`, `Tests/**`, `widgets/otpeek·aas-usage·hello`(기존 수정 시). **금지**: `sdk/**`, `widgets/clock-script/**`, `docs/**`, `README.md`, `schema/**`, `scripts/**`.

1. `RuntimeSupervisor.swift`: 프로세스 생명주기(기동/graceful kill/크래시 루프 감지/재시작), 위 프로토콜의 host 측 전부. JSON-RPC 프레이밍/디스패치는 Core(`JsonRpc.swift`)에 두고 단위 테스트.
2. `entry.kind: "script"` 지원: manifest `entry.runtime: "deno-ts@1"`, deno 탐색 실패 시 오류 카드("Install Deno: brew install deno"), import map 생성.
3. **StorageService**(위젯별 JSON 파일, quota·TTL) / **SecretStore**(Keychain, M1 KeychainStore 확장) / **NotificationService**(UNUserNotificationCenter) — script API와 연결.
4. **권한 강제 + 승인 UI**: `PermissionStore`(App Support JSON — 위젯 id별 승인된 permissions 해시). 미승인/변경된 위젯은 위젯 슬롯에 승인 카드(요구 권한 목록: exec 커맨드·keychain·notifications + Approve/Deny 버튼) 표시, 승인 전 어떤 실행도 금지. manifest 권한 변경 감지(해시 비교) 시 재승인. **감사 로그**: `~/Library/Logs/MenuBucket/audit.log` — exec 실행/차단, secret 접근, 승인/거부 이벤트 (JSON lines, 비밀값 마스킹).
5. 기존 exec 위젯(aas/otpeek/hello)도 동일 승인 프레임에 태움 (기본 번들 위젯은 최초 1회 승인).
6. **테스트**: JSON-RPC 프레이밍/디스패치 단위 테스트 + **스텁 러너 통합 테스트** — `Tests/fixtures/rpc-stub.sh`(bash로 프로토콜 발화: load 수신→host.render 요청→render 응답 확인, exec 요청→PermissionDenied 확인, storage set/get 라운드트립). RuntimeSupervisor의 실행 바이너리를 주입 가능하게 설계(테스트에서 bash 스텁, 프로덕션에서 deno).
7. 검증: `swift build` + 전체 테스트 통과. 노트 → `.context/impl/R03-claude.md`.

## Task B — TS SDK + 예제 + 문서 (담당: Codex 에이전트)

**소유**: `sdk/**`, `widgets/clock-script/**`, `docs/SCRIPT-RUNTIME.md`, `README.md`(스크립트 섹션 추가만). **금지**: Package.swift, Sources/, Tests/, schema/, scripts/, 기존 widgets/.

1. `sdk/mod.ts`: 위 프로토콜의 script 측 구현 — stdin 라인 리더/stdout writer, `mb.widget({load, action, timer})` 등록 + 디스패치, `mb.render/exec.run/storage/secret/timer/notify/log` (모두 JSON-RPC 요청 래퍼, id 자동 증가, pending promise 맵), `ui.*` 헬퍼(vstack/hstack/list/section/text/image/progress/button/badge/banner/empty/divider/spacer — UINode JSON 생성, schema/uinode-0.1.json과 일치). 타입 정의 포함(UINode, Action, ExecResult 등). 외부 의존성 0, deno 표준만.
2. `widgets/clock-script/`: `widget.json`(entry script/deno-ts@1, bucket Demo, 권한: storage만) + `index.ts` — 현재 시각 표시 + 버튼 클릭 카운터(storage 지속) + 1분 timer 재렌더. SDK 사용 시연.
3. `docs/SCRIPT-RUNTIME.md`: 프로토콜 표(위 계약 그대로), SDK API 레퍼런스, clock-script 워크스루, deno 설치/샌드박스 플래그 설명, 크래시 루프 정책. 한국어.
4. `README.md`: "Script widgets (M2)" 섹션 추가 — deno 설치, clock-script 예제 링크.
5. 검증: `deno check sdk/mod.ts widgets/clock-script/index.ts` — **deno 미설치 머신이므로 실패 시 문법 자체 점검으로 대체하고 노트에 명시.** `.context/impl/R03-codex.md` 직접 쓰기 금지(최종 메시지 자동 캡처).
