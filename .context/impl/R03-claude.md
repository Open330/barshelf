# R03 구현 노트 (Task A — 호스트 측 스크립트 런타임)

상태: **완료** (에이전트가 세션 한도로 중단 → 잔여분(rpc-stub 통합 테스트 + JsonRpc 단위 테스트)은 메인 세션이 직접 마무리). `swift build` 통과, 테스트 **60/60**.

## 파일

- `Sources/MenubucketCore/JsonRpc.swift` — JSON-RPC 2.0 프레이밍(`JsonRpcCodec.decode(line:)`/`encode`, sortedKeys 인코딩), `JsonRpcDispatcher`(메서드 테이블, notification 오류 스왈로우).
- `Sources/MenubucketCore/ScriptProtocol.swift` — 프로토콜 v1 파라미터 타입(WidgetLoadParams/ActionParams/TimerParams/RenderParams/RenderStatus, ScriptMethod 상수).
- `Sources/MenubucketCore/RuntimeSupervisor.swift` — actor. 위젯당 상주 프로세스, `ScriptLaunchPlan` 주입(프로덕션 deno / 테스트 bash 스텁), host.render/exec.run(allowlist 강제)/storage/secret(keychain 권한)/timer(once/after/every/clear, minInterval)/notify/log 핸들러, stdout 1MB 라인 제한, stderr→위젯 로그, 크래시 루프(5분 3회→disabled)+`restart`, `retain(widgetIds:)` 핫리로드 정리, SIGTERM→2s→SIGKILL.
- `Sources/MenubucketCore/StorageService.swift` (위젯 네임스페이스 JSON, quota/TTL), `SecretStore.swift`(Keychain `dev.menubucket`, `<widgetId>/<key>` + InMemory 테스트 대역), `AuditLog.swift`(JSON lines + WidgetLogStore 1MB rotate), `PermissionStore.swift`(권한 해시 승인 저장), `ExecService/ExecAllowlist` Core 이동.
- `Sources/MenubucketApp/` — WidgetRuntime에 script entry 연결(권한 승인 카드, deno 탐색 실패 시 설치 안내 카드), NotificationService.
- `Tests/fixtures/rpc-stub.sh` — 시나리오형 스텁(render/exec-denied/exec-ok/storage/secret/timer/log/crash).
- `Tests/MenubucketCoreTests/RuntimeSupervisorTests.swift` — 스텁 통합 8케이스(렌더/allowlist 차단·허용/storage/secret 권한/타이머/액션 포워딩/크래시 루프) + JsonRpc 단위 2케이스.

## 검증

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → 60/60.
- 실제 deno(스크래치패드 바이너리 2.9.1)로 `deno check sdk/mod.ts widgets/clock-script/index.ts` 통과, clock-script에 widget.load 주입 시 유효한 `host.timer.every` 요청 발화 확인 (SDK↔호스트 계약 일치).

## 한계 / 다음

- deno가 시스템에 없으므로 GUI에서 script 위젯은 설치 안내 카드 경로만 검증됨. deno 설치 후 실사용 확인 필요.
- 테스트의 액션 포워딩은 스텁의 단일 스레드 stdin 특성상 순서 대기 필요(waitForCount) — 실제 SDK는 pending map으로 비순차 응답 처리.
- R04: workflow 엔진 + fs.directory/썸네일 + 핀/검색/설정 UI.
