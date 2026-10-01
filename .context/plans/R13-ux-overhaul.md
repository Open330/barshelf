# BarShelf — 설정 창·전체 UX 개편 기획 (R13)

> 작성일: 2026-10-01 | 기준: v0.3.12 (`d97220d`)
> 한 줄 요약: **popover는 보는 곳, BarShelf 창은 관리하는 곳.** 설정은 한 곳에만 두고,
> 우클릭·hover에만 있는 기능을 보이는 UI로 꺼낸다.

---

## 0. 확정된 결정 (2026-10-01)

| # | 결정 | 이유 |
|---|---|---|
| 1 | 최소 macOS를 **14**로 올린다 | `.inspector`, `@Observable`, 개선된 `Form`. P2 인스펙터가 단순해짐 |
| 2 | 설정은 **즉시 반영 + ⌘Z** (Save/Cancel 초안 폐지) | macOS 관례. 지금은 Cancel이 Move Left/Right를 못 되돌림 |
| 3 | Popover 편집 모드는 **순서·삭제·Width만** | 나머지는 BarShelf 창 인스펙터 |
| 4 | Popover 폭 **360 유지**, 높이만 화면에 맞춰 늘림 | |
| 5 | P0에서 **String Catalog만 준비**, 한국어 번역은 마지막 | |

**배포 순서 주의 (결정 1)**: 0.3.12까지의 업데이터는 새 빌드의 최소 macOS를 확인하지 않는다.
macOS 13 사용자가 14 전용 빌드를 받으면 실행할 수 없는 앱으로 교체된다.
그래서 (a) `UpdateInstaller`가 `LSMinimumSystemVersion`을 확인하는 안전장치를 먼저 릴리스하고,
(b) 그 버전이 퍼진 뒤에 최소 버전을 14로 올린다. Homebrew cask의 `depends_on macos`도 같이 올린다.

---

## 1. 진단

### 1.1 같은 설정이 여러 곳에 있다
| 항목 | 지금 위치 | 문제 |
|---|---|---|
| 메뉴 막대 너비·글자·색 | 설정 › Menu Bar, 위젯 시트 › Menu Bar › Look | 프리셋 목록도 두 벌(`appWidePresets`, `presets`) |
| 위젯 크기 | Widgets 탭 Size(XS–L), 위젯 시트 Height(Fit/S/M/L) | 하나는 그리드 너비, 하나는 높이인데 이름이 비슷 |
| 그룹 명칭 | page / panel / bucket 혼용 | |
| 새로고침 | Performance 배율 0.5×–4×, 메뉴 막대 Update 간격 | 카드별 간격 없음. 배율 방향이 불명확 |
| 패널 이동·삭제·Reveal | Widgets 탭 행, popover 카드 우클릭 | |
| 위젯 추가 진입점 | footer +, 빈 화면, 환영 카드, 상태 아이콘 메뉴 | 문구가 4곳 다 다름 |

### 1.2 중요한 것이 숨어 있다
- Quit, 업데이트 확인, 메뉴 막대 승격 목록은 상태 아이콘 **우클릭 메뉴에만** 있음
- 카드 컨트롤은 hover 전까지 투명. 패널 이동·비활성화·삭제는 우클릭 전용
- 카드 헤더 기본 꺼짐 → 오류가 어느 위젯 것인지 모름
- 권한 승인 대기 위젯은 그 페이지를 열기 전까지 신호 없음

### 1.3 탐색이 깊고 비표준
- 설정: 사이드바 → 5칸 segmented → Form (3단). 위젯 시트: 스크롤 → Menu Bar → 3칸 segmented
- 위젯 시트 320pt 고정, Grid 라벨 52pt 고정
- 단축키를 `cmd+shift+b` 텍스트로 입력. ⌘, / ⌘F 는 투명 버튼
- Extensions 탭 안에 JS 편집기, Monitoring은 진단 화면인데 설정 탭

### 1.4 상태에 다음 행동이 없다
- 오류 카드에 재시도 없음, 원시 오류 문자열 노출
- Approve/Deny 동일 모양, 거부 후 삭제 제안 없음
- 업데이트에 "이 버전 건너뛰기" 없음

### 1.5 디자인 기반이 없다
- 토큰·공용 컴포넌트 없음. 9–18pt 하드코딩, 모서리 반경 5종, 고정 폭 수십 개
- `labelsHidden()` + 접근성 라벨 없는 컨트롤 17곳 이상
- Builder 미리보기 카드 ≠ 실제 shelf 카드
- 위젯 본문이 헤더 제목을 다시 그림 (Battery → Battery)

### 1.6 파일이 너무 크다
`WidgetRuntime.swift` 2,949 · `WidgetSettingsView.swift` 1,696 (검색 오버레이 포함) ·
`RootView.swift` 1,167 · `GalleryView.swift` 1,152

---

## 2. 설계 원칙
1. **보는 곳과 관리하는 곳** — popover는 보기·가벼운 정리, 설정·설치·진단은 BarShelf 창
2. **설정은 한 곳에만** — 다른 곳에는 링크만
3. **숨기지 않기** — 우클릭·hover는 지름길일 뿐, 모든 동작은 보이는 UI에서 2클릭 이내
4. **macOS답게** — 사이드바 + grouped Form, 툴바, 인스펙터, 키 녹화기
5. **모든 상태에 다음 행동**
6. **즉시 반영, 되돌리기 가능**

---

## 3. 정보 구조

### 3.1 용어
| 사용자 용어 | 대체 | 뜻 |
|---|---|---|
| **Page** | panel, bucket, group | popover에서 넘기는 한 화면 |
| **Width**: Half / Full | Size XS/S/M/L | 한 줄에 둘 / 혼자 |
| **Height**: Auto / Compact / Tall | Height Fit/S/M/L | 카드 높이 |
| **Refresh**: 위젯별 간격 + 전역 배터리 절약 | Refresh Cadence 배율 | |
| **Widget type**: Command / Workflow / Script | exec / workflow / script | |

내부 이름(`bucket`, `group`)과 설정 파일 스키마는 그대로 둔다. 값이 바뀌는 곳(Width/Height)은 읽을 때 변환한다.

### 3.2 정식 위치
| 위치 | 담는 것 |
|---|---|
| 창 › **Shelf** | 페이지 구성, 위젯 순서·Width·활성화, 위젯별 설정(인스펙터) |
| 창 › **Menu Bar** | 올린 위젯 목록·순서, 공유/개별, 전역 기본 스타일·프리셋 |
| 창 › **Gallery** | 찾기, 상세, 설치·업데이트·제거, URL 설치 |
| 창 › **Create** | 빌더 |
| 창 › **Automation** | 키보드·창 자동화 (현 Extensions) |
| 창 › General / Shortcuts / Updates / Privacy / Advanced | 앱 설정 (Advanced = 배터리 절약, 진단, 로그, 배치 초기화) |
| Popover | 보기, 검색, 새로고침, 편집 모드, ⋯ 메뉴 |
| 상태 아이콘 우클릭 | popover ⋯ 메뉴와 같은 내용 (공유 구현) |

---

## 4. 화면

### 4.1 BarShelf 창
- 사이드바 두 그룹: 작업 공간(Shelf, Menu Bar, Gallery, Create, Automation) / Settings
- 설정 페이지마다 segmented 없이 grouped `Form` 하나
- Shelf: 페이지별 열에 위젯 칩, 페이지 간 끌기, 칩에 상태 배지(오류/승인 필요), 선택 시 인스펙터
- 최소 840×560 유지, 좁으면 인스펙터 접힘

### 4.2 위젯 인스펙터 (320pt 시트 대체)
| 탭 | 내용 |
|---|---|
| General | 활성화, Page, Width, Refresh, manifest 설정, 새 `secret` 타입(키체인) |
| Look | 강조색, Height, 카드 스타일, 헤더 표시 + 실제 카드 미리보기 |
| Menu Bar | 올리기, 공유/개별, 미리보기, 값·단위·경고 기준, 클릭 동작. 스타일은 "기본값 사용"이 기본 |
| About | 버전, 출처, 승인된 권한(회수), 폴더, 복제, 업데이트, 제거 |

popover 카드 톱니바퀴 → 창을 열고 해당 위젯 선택.

### 4.3 Popover
- 헤더: 페이지 이름이 메뉴 버튼(페이지 목록) · 검색 · 새로고침 · ⋯ (Edit Shelf ⌘E, Add Widget ⌘N, Menu Bar ▸, Open BarShelf ⌘,, Check for Updates, Quit ⌘Q)
- 카드 헤더 기본 켜기 (제목, 갱신 상태, 마지막 갱신 시각). 위젯 본문 제목 중복 정리
- 편집 모드: 끌기 손잡이·삭제 항상 표시, 페이지 점 위로 끌어 페이지 이동
- 단축키는 모두 실제 메뉴 항목으로 (투명 버튼 제거)
- 상태 아이콘 배지: 승인 대기·오류
- 단일 카드 popover: 페이지 메뉴 제거, Esc·토스트 지원
- 고정 카드 2개 제한: 없애거나 명시

### 4.4 카드 상태 (`StatusBanner` 하나로)
| 상태 | 모양 | 행동 |
|---|---|---|
| 첫 로딩 | skeleton | — |
| 오래된 값 | 헤더에 "캐시" 배지 | 배지 → 오류·재시도 |
| 오류 | 원인 + 해결 방법, 원문은 "자세히" | 다시 시도(기본), 자세히, 설정 |
| 권한 필요 | 요청 목록 | 허용(기본), 거부 |
| 거부됨 | 축약 카드 | 권한 다시 보기, 제거 |
| 충돌 중지 | 원인 요약 | 다시 시작, 로그 |
| 빈 데이터 | 위젯 정의 또는 기본 문구 | 새로고침, 설정 |

오류 분류: 명령 없음 / 타임아웃 / 네트워크 / JSON 파싱 / 종료 코드.

### 4.5 흐름
- 첫 실행: 환영 창 → 시작 위젯 선택 → 단축키 녹화·로그인 시 실행 → 메뉴 막대 승격 체험 → popover 열기
- 알림 권한: 알림을 쓰는 위젯 설치 시점에 위젯 이름과 함께 요청
- 위젯 추가: 모든 진입점이 "Add Widget…" → Gallery (툴바에 URL 설치, 직접 만들기)
- 업데이트: 실행 시 모달 대신 아이콘 배지 + ⋯ 메뉴 항목, "이 버전 건너뛰기", 자동 확인/설치 설정

---

## 5. 디자인 시스템 (`Sources/MenubucketApp/Design/`)
- 간격 4·8·12·16·24 / 반경 6(컨트롤)·10(카드)·14(큰 면)
- 글자: 시스템 의미 스타일만, 위젯 큰 숫자용 `display` 하나
- 색: 시스템 의미 색 + `WidgetAppearance.accentColor` + 상태 색 토큰
- 힌트는 `.secondary` 이상
- 컴포넌트: `SettingsPage`, `InspectorSection`, `StatusBanner`, `KeyRecorder`, `AccentPicker`,
  `SymbolPicker`, `EmptyState`, `StatBadge`, `WidgetCardChrome`(popover·단일 카드·빌더·인스펙터 공용)
- 접근성: 숨은 hover 컨트롤은 접근성 트리에서도 숨김, 색만으로 상태 표시 금지, 고정 폭 제거

---

## 6. 코드 구조
| 지금 | 나눌 곳 |
|---|---|
| `WidgetSettingsView.swift` | `Inspector/` 탭별, `Search/SearchOverlay.swift`, `MenuBar/MenuBarSettings.swift` |
| `RootView.swift` | `Popover/PopoverView`, `PagerState`, `WidgetCardView`, `CardStates`, `WelcomeView` |
| `GalleryView.swift` | `GalleryModel`, `RequirementProbe`, `GalleryView`, `GalleryCard`, `GalleryDetail` |
| `WidgetRuntime.swift`의 승인·중지 카드 | 런타임은 상태만, 그리기는 `CardStates` |
| `StatusItemController.swift` | `AppMenu`(⋯ 메뉴와 우클릭 공유), `PopoverInput`, `SingleCardPopover` |
| `AppPrefs.update` 필드별 복사 | 값 타입 통째 갱신 |

---

## 7. 로드맵 (단계마다 PR, 단독 배포 가능)
- **P0 기반**: 업데이터 최소 macOS 안전장치(먼저 릴리스) → macOS 14, 토큰·컴포넌트, 파일 분할,
  메뉴 단축키, `AppPrefs.update`, 용어 통일, String Catalog 준비. *완료 기준: 화면 변화 없음, UI 파일 800줄 이하*
- **P1 창 구조**: 새 사이드바, Form 설정 페이지, Menu Bar 페이지, Automation 독립, Advanced, KeyRecorder, Updates 설정.
  *완료 기준: 설정 어디든 사이드바 1클릭, segmented 중첩 없음*
- **P2 Shelf·인스펙터**: 페이지 열 배치, 페이지 간 끌기, 인스펙터, 즉시 반영·⌘Z, `secret`, 권한 회수.
  *완료 기준: 시트 삭제, 메뉴 막대 스타일은 Menu Bar 페이지 한 곳*
- **P3 Popover**: ⋯ 메뉴, 페이지 메뉴, 카드 헤더, 편집 모드, 카드 상태, 승인 기본 버튼, 아이콘 배지.
  *완료 기준: 우클릭 없이 모든 동작, 오류 카드마다 재시도*
- **P4 Gallery**: 네이티브 검색, 종류 이름, 상세 화면, 제거, URL 설치 툴바, 개인 도구 이름 제거, 이슈 #1
- **P5 마감**: 첫 실행, 빌더 미리보기 일치, 번들 위젯 제목 중복, VoiceOver, 번역, `ScreenshotMode` 갱신

진행 중이던 Automation(Hammerspoon) 작업은 P0가 `AppSettingsView`/`StatusItemController`/`main.swift`를
건드리기 전에 먼저 머지한다.
