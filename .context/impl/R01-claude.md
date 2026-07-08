# R01 M0 구현 노트 — Task A (Swift 패키지 전체)

- 작성: Claude 에이전트, 2026-07-08
- 검증: `swift build` 통과, `swift test` 15/15 통과 (테스트는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 필요 — 아래 "알려진 한계" 참조)

## 파일 목록

```
Package.swift                                   swift-tools 5.9, macOS 13+, 외부 의존성 0
Sources/MenubucketCore/
  UINode.swift                                  type 판별자 + 전 필드 옵셔널 Codable, ImageSource, NodeAction, KnownType enum
  Manifest.swift                                M0 부분집합 Codable (permissions/settings 등 미지 키 관용)
  WidgetSnapshot.swift                          last-good 렌더 상태 + isStale() + ISO8601 JSON 직렬화 (isLoading은 비영속)
  AasUsageAdapter.swift                         aas usage --json → UINode 트리 (Foundation-only, 테스트 대상)
Sources/MenubucketApp/
  main.swift                                    NSApplication + .accessory + AppDelegate
  StatusItemController.swift                    file-stack 패턴: variableLength, sendAction [.leftMouseUp,.rightMouseUp], 좌클릭 토글/우클릭 NSMenu(Refresh All/Quit), 팝업 스코프 키보드 모니터(←/→, ⌘1..9, Esc)
  PopupSurface.swift                            PopupSurface 프로토콜 + PopoverSurface(NSPopover .transient, NSHostingController, 360×480, onShow/onHide 훅)
  ExecService.swift                             바이너리 탐색($ENV → ~확장 절대경로 → PATH+폴백 /opt/homebrew/bin:/usr/local/bin:~/.cargo/bin), no-shell Process, timeoutMs(SIGTERM→2s 후 SIGKILL), stdout 1MB 제한, stderr 별도 drain(64KB)
  WidgetRuntime.swift                           manifest 로드(./widgets → ~/Library/Application Support/menubucket/widgets, id 중복 시 dev 우선), 스냅샷 발행, onOpen+stale 갱신, interval 타이머(팝업 열림 중만, 최소 5s), in-flight coalescing, last-good-render 유지, adapter 레지스트리, 디스크 렌더 캐시(~/Library/Application Support/menubucket/cache/<id>.json)
  ActionRouter.swift                            copyText/openURL/openFile/revealFile/refresh, event는 M0 no-op 로그
  Renderer/ViewTreeRenderer.swift               UINode → SwiftUI 재귀 렌더러 (13개 v0 노드, 알 수 없는 type은 "⚠︎ unsupported" placeholder, id 기반 ForEach identity, ActionContext environment)
  RootView.swift                                bucket.group=페이지, order 정렬, 화살표+도트+키보드 페이저, WidgetCardView(이름 헤더/에러 시 "Showing cached data" 배너/updatedAt 캡션/로딩 시 캐시 우선)
Tests/MenubucketCoreTests/
  UINodeTests.swift                             라운드트립, 알 수 없는 type·필드 디코딩 성공, 액션 디코딩
  ManifestTests.swift                           예제 widget.json 2종 실파일 파싱, permissions/settings/미지 키 관용, 필수 필드 누락 실패
  WidgetSnapshotTests.swift                     직렬화 라운드트립(isLoading 비영속), staleness 판정
  AasUsageAdapterTests.swift                    구조/severity 틴트/배지·에러 행/ID 유일·결정성/가비지 입력 배너/빈 계정 empty
widgets/aas-usage/widget.json                   output=data, adapter aas-usage, discover 체인, staleAfterSec 600
widgets/hello/widget.json + hello.sh(755)       output=viewtree 셸 스크립트: 시각 text, 분 progress, copyText 버튼
```

## 설계 이탈

1. **AasUsageAdapter를 MenubucketApp이 아닌 MenubucketCore에 배치** — 태스크 A4가 허용한 옵션. Foundation만 사용하며 어댑터 출력 구조를 유닛 테스트로 검증하기 위함. App 쪽 레지스트리(`WidgetRuntime.adapters`)는 그대로 `[String: (Data) -> UINode]`.
2. **aas 헤더의 "갱신 상대시간" 생략** — adapter는 순수 `(Data) -> UINode`라 트리에 시각을 박으면 캐시 표시 시 거짓 정보가 됨. 대신 위젯 카드 공통 푸터가 `updatedAt`을 상대시간("Updated 3m ago")으로 항상 표시하므로 정보는 동일하게 노출.
3. **copyText 토스트** — 오버레이 토스트 대신 `NSSound.beep()` + 로그로 단순 피드백(M0). 토스트 UI는 M1 후보.
4. **`./` 상대 command 해석 추가** — hello처럼 위젯이 스크립트를 동봉하는 경우를 위해, discover가 없고 command[0]가 `./`로 시작하면 위젯 디렉토리 기준으로 해석(Process cwd도 위젯 디렉토리). 스펙에 명시 없던 부분의 보수적 확장.
5. **meter의 `resetMs`는 파싱만 하고 미표시** — 단위/기준(epoch ms 추정)이 스펙에 불명확해 렌더 보류.

## 알려진 한계

- **`swift test`는 풀 Xcode 필요**: 이 머신의 `xcode-select`가 CommandLineTools를 가리키는데 CLT에는 XCTest가 없음. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`로 통과 확인(15/15). `swift build`는 CLT만으로 통과. `sudo xcode-select -s`는 시스템 설정 변경이라 하지 않음.
- NSPopover `.transient`: 상태아이템 재클릭 시 "닫힘→즉시 재열림" 플리커 가능성(전형적 transient 이슈). M1 NSPanel 전환 시 해소 예정.
- 페이지 전환은 버튼/도트/키보드만 — 트랙패드 스와이프는 M1 스펙.
- interval 타이머는 팝업 열림 중에만 동작(스펙 불변식 3 준수). `runInBackground`는 미구현(M0 범위 외).
- ExecService의 지수 백오프·크래시 루프 disabled 전환(불변식 5)은 M0 범위 외로 미구현.
- 렌더 캐시는 앱 재시작 후에도 last-good을 복원하지만, manifest 변경 시 캐시 무효화 로직은 없음(스키마가 전방 호환이라 실해는 없음).
- GUI 실행은 미검증(`swift run` 금지 지시 준수) — 빌드/링크 성공까지 확인.

## 다음 단계 제안

1. `swift run` 수동 스모크: 팝업 열기 → hello viewtree 렌더 / aas 미터 렌더 / aas 부재 시 배너+캐시 확인, 상주 메모리 <50MB 측정.
2. Task B의 `scripts/build_app.sh`로 번들 조립 후 위젯 리소스 경로(현재 cwd 기준 `./widgets`)가 번들 내 Resources를 볼지 결정 — 번들 실행 시 `Bundle.main.resourceURL/widgets`를 탐색 경로에 추가하는 소패치 필요할 수 있음.
3. M1: NSPanel PopupSurface, 스와이프 페이저, deadline/watch 트리거, hot reload, 토스트 오버레이.
4. 크래시 루프 감지(5분 내 3회 → disabled + Restart CTA), 지수 백오프.
