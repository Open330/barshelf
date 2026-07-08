# R05 Track A — 성능 점검·개선 노트

측정 환경: `bash scripts/build_app.sh && open dist/MenuBucket.app` → 60초 유휴(팝업 닫힘) 후
`ps -o rss=,pcpu=` 3회(5초 간격) + `top -pid <pid> -l 3 -stats pid,cpu,mem,pageins | tail -3`.
측정 후 `pkill -f dist/MenuBucket`. 빌드/테스트는 전부 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Before / After (유휴, 팝업 닫힘)

| 지표 | Before (baseline) | After | 목표 |
|---|---|---|---|
| CPU (ps pcpu, 3샘플) | 0.0 / 0.0 / 0.0 % | 0.0 / 0.0 / 0.0 % | ≈0.0~0.1% ✅ |
| RSS (ps rss, 3샘플) | 41,952 KB ≈ 41.0 MB | 35,344 / 35,424 / 35,424 KB ≈ 34.6 MB | < 50 MB ✅ |
| top %CPU / MEM / pageins | 0.0% / 10M / 317 | 0.0% / 11M / 6 | — |
| 스레드 수 (ps -M) | 4 | 4 | — |
| 위젯 1개 갱신 시 타 카드 리렌더 | 전체 카드 리렌더(코드 근거 아래) | 해당 카드만(코드 근거 아래) | ✅ |

유휴 수치는 baseline부터 이미 목표 충족 — 팝업 닫힘 상태 타이머/틱이 애초에 잘 억제되어 있었음.
(RSS -6MB와 pageins 317→6은 재실행 시 워밍/캐시 상태 차이가 섞여 있어 코드 효과로 단정하지 않음.)
이번 라운드의 실질 개선은 **팝업 열림 중 리렌더 격리**와 **갱신 핫패스의 메인 스레드 디스크 I/O 제거**.

## 점검 항목별 결과

1. **팝업 닫힘 중 타이머** — 문제 없음(수정 불필요).
   `SchedulePolicy.effectiveInterval`이 닫힘+`runInBackground=false`면 nil을 반환해 interval 타이머가 아예
   안 만들어지고, deadline 타이머는 `popupClosed()`에서 전부 취소(deadline 값만 보존, 열릴 때 재평가).
   watch 이벤트는 닫힘 중 pending set에만 쌓였다가 열릴 때 일괄 refresh. 유휴 CPU 0.0% 실측과 일치.

2. **`@Published snapshots` 전체 무효화** — 수정함 (핵심 변경).
   - Before: `WidgetRuntime.snapshots`/`overlayCards`가 `@Published` dict → 위젯 1개 갱신마다
     `runtime.objectWillChange` 발행 → `RootView`와 **모든** `WidgetCardView`(`@ObservedObject var runtime`)가
     body 재평가.
   - After: `WidgetCardModel: ObservableObject`(위젯별 `@Published snapshot` + `@Published overlay`) 도입.
     `snapshots`/`overlayCards`는 non-published 소스오브트루스로 유지하고 모든 쓰기를
     `setSnapshot(_:for:)`/`setOverlay(_:for:)` 단일 경로로 라우팅 — **Equatable 비교로 동일 값 재쓰기는 발행
     억제**, 변경 시 해당 위젯의 모델만 발행. `WidgetCardView`는 runtime을 비관찰(let)로 들고
     `@ObservedObject model = runtime.cardModel(for:)`만 구독.
   - 코드 근거: 위젯 X 갱신 → `setSnapshot` → `cardModels[X]!.snapshot` 발행 → X 카드만 body 재평가.
     `runtime.objectWillChange`는 스냅샷 경로에서 더 이상 발행되지 않으므로(`widgets` 변경 = 핫리로드 시에만)
     타 카드/RootView는 무효화되지 않음.
   - 트레이드오프: `WidgetSettingsView`의 렌더 프리뷰(runtime.snapshots 직접 읽기)는 시트가 떠 있는 동안
     라이브 갱신되지 않음(열 때 시점 값). 시트 UI라 수용.

3. **countdown `TimelineView` 닫힘 시 중단** — 문제 없음.
   팝업은 `NSPopover` + `NSHostingController`(PopupSurface.swift). 닫히면 콘텐츠 뷰가 윈도우에서 제거되어
   TimelineView 틱 중단(뷰 해제로 자동). 유휴 CPU 0.0% 3샘플 실측으로 확인(번들 위젯에 countdown 포함 상태).

4. **ThumbnailService** — 보강.
   - `cache.totalCostLimit = 32MB` 추가(기존 countLimit 200 병행), `setObject(cost:)`에 픽셀×4 근사 비용
     (`cacheCost(of:)`, representations의 최대 pixelsWide×pixelsHigh 기준).
   - 스케일: QL 요청이 pointSize + backingScaleFactor로 생성 → 과대 생성 아님(적정).
   - 디스크 프루닝: init에서 전용 utility 큐로 async 실행 — 메인 차단 없음(기존 OK).

5. **ExecService / RuntimeSupervisor** — 문제 없음.
   - ExecService: `capture()`가 `withCheckedContinuation` + `DispatchQueue.global(qos: .utility)`로 blocking
     작업(waitUntilExit, pipe read)을 코오퍼레이티브 풀 밖에서 수행. pipe read는 `availableData` blocking
     루프(busy-poll 아님). `waitUntilExit`가 자식 회수(좀비 없음), 타임아웃 시 terminate→2초 후 SIGKILL.
   - RuntimeSupervisor: stdout/stderr `readabilityHandler`(이벤트 기반), `terminationHandler`로 회수.

6. **스냅샷 persist 핫패스** — 수정함.
   - Before: `persistSnapshot`이 갱신마다 **메인 스레드에서 동기** JSON 인코딩+디스크 쓰기(atomic).
   - After: 위젯별 0.5초 debounce(`pendingPersists` DispatchWorkItem) + 전용 utility 직렬 큐
     (`dev.menubucket.snapshot-cache`)에서 인코딩·쓰기. sensitive 전환 시 pending 쓰기 cancel 후 캐시 삭제
     (민감 렌더가 디스크에 남지 않는 기존 불변식 유지). 종료 직전 마지막 0.5초 내 쓰기는 유실 가능 — 렌더
     캐시 특성상 수용(다음 성공 렌더가 재생성).

7. **앱 시작 비용** — 문제 없음.
   시작 시 manifest 스캔 + 캐시 스냅샷 로드만 수행, 위젯 실행은 없음(첫 팝업 열림/백그라운드 interval에서만).
   script supervisor도 lazy 생성. 60초 유휴 pageins 317, RSS 40MB 수준.

## 변경 파일

- `Sources/MenubucketApp/WidgetRuntime.swift` — `WidgetCardModel` 도입, snapshots/overlayCards 발행 라우팅
  (`setSnapshot`/`setOverlay`/`cardModel(for:)`/`removeWidgetState`), persist debounce+백그라운드화.
- `Sources/MenubucketApp/RootView.swift` — `WidgetCardView`가 runtime 비관찰 + 자기 `WidgetCardModel`만 구독.
- `Sources/MenubucketApp/ThumbnailService.swift` — `totalCostLimit`(32MB) + 비용 기반 `setObject`.
- `Tests/MenubucketCoreTests/WidgetSnapshotTests.swift` — 발행 억제가 의존하는 Equatable 의미론 고정 테스트 추가.

테스트: 70/70 통과 (기존 69 + 신규 1, `swift test`).

## 남은 개선 후보

- `WidgetCardView`의 "Updated N min ago" 캡션이 스냅샷 발행 시점에만 갱신 — 표시 최신화가 필요하면 카드별
  느린(60s) TimelineView 고려(현재는 발행 억제 유지 우선).
- `WidgetSettingsView` 프리뷰를 `WidgetCardModel` 구독으로 전환하면 라이브 프리뷰 복원 가능(파일 소유권상 이번
  트랙에서 미변경).
- 디스크 썸네일 재로드 시 NSImage 포인트 크기가 픽셀 크기로 잡히는 사소한 비일관(표시엔 무해) — 캐시에 scale
  메타를 넣으면 정리 가능.
- 앱 종료 훅에서 pendingPersists flush(현재는 최대 0.5초 유실 허용).
