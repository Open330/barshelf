# R02 M1 구현 노트 — Task A (Swift 전체)

- 작성: Claude 에이전트, 2026-07-08
- 검증: `swift build` 통과(경고 0), `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` **50/50 통과** (M0 15개 + M1 35개)

## 파일 목록 (신규 ★ / 수정 ✎)

```
Sources/MenubucketCore/
  UINode.swift ✎            countdown progress 공통 계약: style("linear"|"ring"), countdown{from,until}(epoch ms),
                            labelFrom("remainingSeconds"), tintRules[{whenRemainingLtSeconds,tint}] + 헬퍼
                            (countdownRemainingSeconds/Fraction/Tint — Core에서 테스트).
                            NodeAction 확장: run{command,thenRefresh}, copyText.clearAfterSec. Sendable 부여.
  Manifest.swift ✎          v0.1 전체: refresh.deadlineField(예약)/watchPaths/runInBackground,
                            statusItem{mode,icon,labelFrom,tooltipFrom}(디코딩+none만 동작),
                            permissions{exec[{command,allowedArgs[[String]],env,maxOutputBytes,sensitiveOutput}],
                            network,readPaths,env,keychain}, settings[](디코딩만, default는 JSONValue).
  ExecAllowlist.swift ★     allowlist 매처: command==argv0 또는 basename, allowedArgs 패턴 요소별 매칭("*"=정확히 1개 인자,
                            길이 불일치 불허), nil allowedArgs=모든 인자 허용/[]=bare command만.
  SchedulePolicy.swift ★    effectiveInterval(열림 min 5s / 닫힘 runInBackground만 4배·min 60s),
                            BackoffState(15→60→300s 캡, 성공 시 리셋, 자동 트리거만 게이트).
  Adapter.swift ★           M1 adapter 계약: AdapterResult{viewTree,nextRefreshAtMs,statusText},
                            AdapterContext(Sendable, runAllowed(command:) async throws -> Data), AdapterError.
  AasUsageAdapter.swift ✎   신규 시그니처 adapt(Data, AdapterContext) 추가(순수 adapt(Data) 유지, statusText=worst%).
  OtpeekAdapter.swift ★     list --json 디코딩(secret은 모델링 안 함) → totp 필터 → 계정별
                            `otpeek code <id> --json` TaskGroup 병렬 실행(순서 보존) → 행: issuer/accountName +
                            그룹핑 코드 버튼(copyText, clearAfterSec 30) + countdown ring(<10s danger).
                            nextRefreshAtMs = min(validUntil)+250. 전 계정 패스워드 실패 시 Keychain 안내 포함 오류,
                            미설치/파싱 실패는 AdapterError로 오류 카드.
Sources/MenubucketApp/
  DirectoryWatcher.swift ★  file-stack 패턴 이식 + 다중 경로 + trailing debounce(기본 250ms), 메인 큐 콜백.
  KeychainStore.swift ★     읽기 전용 generic password 조회(service dev.menubucket),
                            env 변수→계정명 매핑(OTPEEK_VAULT_PASSWORD→otpeek-vault-password).
  Scheduler.swift ★         트리거 오케스트레이션: interval(열림/닫힘 정책은 SchedulePolicy), deadline(팝업 열림 중만
                            armed, 닫히면 취소·저장, 열림 시 재평가, 정확히 1회), watch(FSEvents 250ms debounce,
                            닫힘 중 pending → 열림 시 일괄), NSWorkspace.didWakeNotification(닫힘 중엔
                            runInBackground만 stale 갱신), 백오프 게이트(noteSuccess/noteFailure).
  ExecService.swift ✎       extraEnvironment(상속 env 위에 merge), stdoutLimit(권한별 maxOutputBytes), async 래퍼.
  WidgetRuntime.swift ✎     async refresh 파이프라인(exec → adapter(Data,ctx) → snapshot+deadline 전달),
                            HostAdapterContext(allowlist 강제+discover 재사용+secret env), source.command도
                            allowlist 선언 시 검증, 미지원 entry.kind는 로드 성공+오류 카드,
                            sensitive 위젯 디스크 캐시 제외+기존 캐시 삭제, 핫 리로드(위젯 디렉토리 FSEvents →
                            재스캔, id 기준 스냅샷 보존, 제거 위젯 정리), performRun(run 액션, 불일치 차단+로그),
                            Keychain 패스워드 오류 시 `security add-generic-password …` 안내 부착.
  ActionRouter.swift ✎      run 액션 라우팅, copyText clearAfterSec(NSPasteboard changeCount 동일할 때만 소거,
                            값은 로그 금지).
  Renderer/ViewTreeRenderer.swift ✎  countdown 노드: TimelineView(.periodic 1s) 자체 틱(뷰가 화면에서 사라지면
                            틱 중단=팝업 닫힘), ring(트랙+trim 원호+중앙 남은 초, size=지름 기본 26) / linear(+남은 초),
                            tintRules 적용. countdown 없는 style:"ring"+value도 지원.
  RootView.swift ✎          스와이프 페이저: 페이지들을 HStack 스트립으로 배치, offset = -index*width + dragOffset,
                            스와이프 중 무애니메이션 1:1 추적 → 릴리즈 시 spring 스냅(임계 1/3 폭),
                            에지 러버밴드(0.25 감쇠). 기존 도트/←→/⌘1..9 유지. PagerState에 스와이프 API 추가.
  StatusItemController.swift ✎  팝업 스코프 scrollWheel 로컬 모니터: phase 추적, 제스처당 1회 축 판정(|dx|>|dy|),
                            수평이면 이벤트 소비+페이저 구동, 수직/레거시 휠은 통과(버킷 내 세로 스크롤 무충돌),
                            수평 제스처의 momentum tail 소비.
widgets/otpeek/widget.json ★  otpeek 위젯: discover $OTPEEK_BIN→~/.cargo/bin→brew→PATH, output=data/adapter=otpeek,
                            permissions.exec allowedArgs [["list","--json"],["code","*","--json"]],
                            sensitiveOutput true, keychain true, env OTPEEK_BIN/OTPEEK_VAULT_PASSWORD.
Tests/MenubucketCoreTests/
  ExecAllowlistTests.swift ★   와일드카드/길이/서브커맨드/바이너리/basename/빈 allowlist 매칭·차단 9종.
  SchedulePolicyTests.swift ★  interval 정책(전경 clamp/배경 4배·60s floor/차단), 백오프 15→60→300 캡·게이트·리셋, staleness.
  CountdownNodeTests.swift ★   계약 예제 그대로 디코딩·라운드트립, remaining/fraction/tintRule 계산, run/clearAfterSec 액션 디코딩.
  OtpeekAdapterTests.swift ★   list+code 픽스처(mock AdapterContext): 행 구조·hotp 필터·ring 계약·코드 그룹핑·
                            copyText(원본 값+clearAfterSec 30)·nextRefreshAtMs(min+250)·부분 실패 행·
                            전체 패스워드 실패 시 Keychain 안내·가비지 입력·빈 vault.
  ManifestV01Tests.swift ★     otpeek/aas 실제 manifest 전체 디코딩, refresh/statusItem/settings 풀 필드,
                            미지원 entry.kind 디코딩 허용, Codable 라운드트립.
```

## 설계 이탈 / 해석

1. **otpeek CLI 계약은 실제 소스에서 확인** (`~/workspace/otpeek/core/crates/otpeek-cli`): `list --json`은 camelCase `OtpAccount` 배열(`secret` 포함 → 어댑터 모델에서 의도적으로 미모델링), `code <id> --json`은 `{code,validFrom,validUntil}`(epoch ms). 픽스처가 이 형태를 그대로 따름.
2. **Keychain env 주입 일반화**: 태스크의 otpeek 특정 규칙(account `otpeek-vault-password`)을 "keychain:true + 선언된 env 변수 중 호스트 env에 없는 것 → account = lowercase(`_`→`-`) 조회"로 일반화. otpeek 케이스는 정확히 태스크 명세와 일치.
3. **allowlist 매칭 규칙 구체화**(스펙 미정 부분): 패턴과 인자 수 동일해야 매칭("*"=정확히 1개), `allowedArgs` 생략=모든 인자 허용, `[]`=bare command만. 선언된 `permissions.exec`가 있으면 **source.command도** 매칭 필수(없으면 M0 호환으로 비강제 — hello 위젯 보호).
4. **어댑터 추가 exec의 discover**: 별도 필드가 없어, argv0가 source.command[0]와 같으면 source.discover 체인 재사용(otpeek code가 otpeek list와 같은 바이너리 탐색을 공유).
5. **wake 트리거**: 팝업 닫힘 중엔 runInBackground 위젯만 즉시 갱신(불변식 3), 나머지는 다음 onOpen staleness가 처리.
6. **run 액션 실패 처리**: 차단은 로그만(스펙대로), 실행 실패는 snapshot.error 배너로 표면화.
7. **NSPanel 전환은 검토만**: 스와이프가 NSPopover 안에서 로컬 scrollWheel 모니터로 충돌 없이 동작해 M1에서는 전환하지 않음(PopupSurface 추상화 유지, D5의 "검토" 범위).

## 알려진 한계

- otpeek 실기기 미설치라 어댑터는 픽스처 기반 검증(CLI 소스와 형태 대조 완료). 미설치 시 오류 카드+탐색 경로 안내는 ExecService binaryNotFound 경로로 동작.
- countdown 틱은 TimelineView 의존 — 뷰가 윈도우에서 내려가면(팝업 닫힘) 자동 중단되지만, 명시적 stop API는 아님.
- 스와이프 러버밴드는 상수 감쇠(0.25) 근사(거리 비례 곡선 아님). 관성(velocity) 기반 스냅은 미구현 — 임계값(폭 1/3) 방식.
- `settings[]`/`statusItem`은 디코딩만(M2), `refresh.deadlineField`는 예약 필드로 디코딩만.
- deadline 타이머는 wall-clock 재평가를 팝업 open 시에만 수행 — 열림 중 시스템 sleep→wake 시 Timer 지연 가능(wake 핸들러가 stale 갱신으로 보완).
- 백오프 상태는 메모리 전용(앱 재시작 시 리셋). 크래시 루프 → disabled 전환(불변식 5)은 여전히 미구현(M2 후보).
- GUI 실행 미검증(`swift run` 금지 준수) — 빌드/링크/유닛테스트까지 확인. 스와이프·ring 렌더·Keychain 주입은 수동 스모크 필요.

## 다음 단계 제안

1. 수동 스모크: otpeek 설치 후 Keychain 등록(`security add-generic-password -s dev.menubucket -a otpeek-vault-password -w`) → 팝업에서 코드 롤오버(만료+250ms 정확히 1회 재실행)·클릭 복사·30s 클립보드 소거 확인.
2. 트랙패드 스와이프 실사용 감성 튜닝(임계값/스프링 파라미터), 필요 시 NSPanel 전환(D5).
3. copyText 토스트 오버레이(현재 beep), 위젯 disabled 전환+Restart CTA.
4. Task B 산출물(schema/uinode-0.1.json)과 UINode 필드 명세 상호 대조.
