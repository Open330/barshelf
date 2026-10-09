# BarShelf — Dock 기획 (R15)

> 작성일: 2026-10-07 | 기준: v0.6.0 + main(`80deb71`)
> 한 줄 요약: **BarShelf 위젯과 앱 런처를 화면 가장자리의 독에 올리고, 상황마다 독 구성을 바꾼다.**
> 메뉴바가 여전히 중심이며, 독은 전부 옵션이다(기본값은 꺼짐).
> 참고 제품: Dockset (dockset.app) — Apple Dock 레이아웃 전환 + 위젯이 있는 별도 독.

---

## 0. 결정 (사용자 요청: "가능하다면 옵션으로 모두 제공")

| # | 질문 | 결정 |
|---|---|---|
| 1 | 독의 형태 | **BarShelf Dock**: 화면 가장자리(아래·왼쪽·오른쪽)에 붙는 non-activating 패널. 앱·폴더·파일·링크·Shortcuts·구분선·**BarShelf 위젯**을 올린다 |
| 2 | Apple Dock과의 관계 | 세 모드를 옵션으로: **끄기**(기본) / **Apple Dock과 함께** / **Apple Dock 대체**(Apple Dock 숨김) |
| 3 | 프로필 | 독 구성을 **프로필**(Work, Personal…)로 저장. 프로필 하나가 BarShelf Dock 아이템 + (선택) Apple Dock 레이아웃 + (선택) 팝업 페이지를 가진다 |
| 4 | Apple Dock 레이아웃 전환 | 옵션. 프로필에 Apple Dock의 현재 고정 앱을 **그대로 저장**하고, 전환 시 되돌려 쓴다 |
| 5 | 전환 방법 | 단축키(⌃⌥1…9, 옵션), 독 위 두 손가락 스와이프 / ⌘+스크롤, 메뉴바 메뉴, `barshelf://dock?profile=`, `barshelf dock use`, Shortcuts 자동화(Focus) |
| 6 | 스타일 | **Classic**(Apple Dock처럼: 아이콘, 확대, 실행 중 점) / **Shelf**(위젯이 잘 보이는 넓은 막대). macOS 26+에서는 Liquid Glass |

## 1. 가능 여부 (조사 결과)

- **Apple Dock 읽기/쓰기:** `com.apple.dock`의 `persistent-apps`(앱), `persistent-others`(폴더·파일) 배열.
  BarShelf는 샌드박스가 아니므로 `CFPreferences`로 읽고 쓸 수 있다. 쓴 뒤 Dock 프로세스를 재시작해야 반영된다
  (`killall Dock`, launchd가 바로 다시 띄움). dockutil과 같은 방식. 이 Mac(macOS 27.0.1)에서 읽기 확인.
  - 저장은 **원본 배열을 그대로**(타일 안의 bookmark 데이터 포함) → 되돌릴 때 손실이 없다.
  - 새 타일을 만들 때는 `file-data._CFURLString` + `_CFURLStringType = 15`만 넣으면 Dock이 나머지를 채운다.
  - 실행 중인 앱·창은 건드리지 않는다. Dock 재시작 때 0.5초 정도 깜빡인다.
- **Apple Dock 숨기기:** 공개 API 없음. 업계 표준 방식 = `autohide = true` + `autohide-delay = 1000` + Dock 재시작.
  원래 값(`autohide`, `autohide-delay`)을 **먼저 백업**하고, 모드를 끄면 복원한다.
  - BarShelf가 비정상 종료돼도 복구되도록: 백업은 `dock.json`에 남고, 다음 실행 때 "대체" 모드가 아니면 복원한다.
    BarShelf 없이도 `barshelf dock restore-apple-dock`(CLI)로 복원할 수 있다.
- **화면 공간 예약:** 공개 API로는 다른 앱 창이 독을 피하게 만들 수 없다(`visibleFrame`은 Apple Dock만 반영).
  → "자동 숨기기"를 제공하고, 대체 모드에서는 기본으로 켠다. Dockset·uBar도 같은 한계.
- **자동 숨기기:** 화면 가장자리에 2pt짜리 투명 감지 패널 + `NSTrackingArea`. 권한(손쉬운 사용) 불필요.
- **실행 중인 앱:** `NSWorkspace.runningApplications` + 실행/종료/활성화 알림. 권한 불필요.
  - 안 되는 것: 앱 배지(읽지 않은 메일 수 등, 비공개 API), 창 미리보기·최소화된 창(손쉬운 사용·화면 기록 권한) → 범위 밖.
- **Focus 연동:** 지금 켜진 Focus의 **이름**을 읽는 공개 API가 없다(`INFocusStatus`는 켜짐/꺼짐뿐, 별도 권한 필요).
  → Shortcuts 개인 자동화 "Focus가 켜지면 → URL 열기 `barshelf://dock?profile=Work`"로 연결하고 문서화한다.
  시스템 설정의 Focus Filter(App Intents)는 Xcode가 만드는 메타데이터가 필요하다(R14와 같은 문제) → 후속 과제.
- **위젯 갱신:** 독에 보이는 위젯은 메뉴바 위젯처럼 "항상 화면에 있음"으로 스케줄러에 알린다
  (팝업이 닫혀 있어도 자기 주기로 갱신). 독이 숨겨져 있으면(자동 숨김) 대상에서 뺀다.

## 2. 구조

```
dock.json (Application Support/barshelf)        ← Core: DockConfiguration (Codable, 테스트)
  mode: off | alongside | replace
  style, edge, tileSize, autoHide, magnification, showRunningApps, showTrash
  profiles: [ { id, name, symbol, items: [DockItem], appleDock: snapshot?, popupPage? } ]
  activeProfileID, switchingHotkeys, appleDockLayouts(on/off)
  appleDockBackup: { autohide, autohideDelay }?    ← 대체 모드 복구용

DockItem = app(path) | folder(path, color, label) | file(path) | link(url, title)
         | shortcut(name) | widget(id) | spacer | separator

App
 ├─ DockStore            dock.json 관찰·저장, 프로필 전환
 ├─ AppleDockController  persistent-apps 읽기/쓰기, 숨기기/복원, Dock 재시작
 ├─ DockPanelController  NSPanel(독 레벨), 가장자리 배치, 자동 숨김, 스와이프
 │    └─ DockView (SwiftUI)  아이템 타일, WidgetCardView 재사용, 드래그 앤 드롭
 ├─ GlobalHotkeys        ⌃⌥1…9 프로필 단축키 (Carbon, 권한 불필요)
 └─ Hub ▸ Dock 페이지     모드·스타일·프로필 편집
CLI: barshelf dock list | use <profile> | restore-apple-dock
URL: barshelf://dock?profile=<id 또는 이름>, barshelf://dock?next / ?previous
```

## 3. 단계 (PR 단위)

1. **계획(이 문서).**
2. **BarShelf Dock:** Core 모델·저장·테스트, 패널, 아이템(앱·폴더·파일·링크·Shortcuts·위젯·구분선·휴지통),
   실행 중인 앱, 드래그로 추가·순서 변경, 우클릭 메뉴, 자동 숨김, Classic/Shelf 스타일, Hub의 Dock 페이지.
3. **프로필과 Apple Dock:** 프로필 전환(단축키·스와이프·메뉴·URL·CLI), Apple Dock 레이아웃 저장/적용,
   대체 모드(숨김·백업·복원), Focus용 Shortcuts 안내, 문서(docs/DOCK.md), 한국어.

## 4. 위험

- **Apple Dock을 숨긴 채로 BarShelf가 죽으면** 사용자는 Dock이 사라진 것처럼 느낀다
  → 백업 + 다음 실행 때 복원 + CLI 복원 + 문서. 대체 모드를 켤 때 복원 방법을 한 번 보여 준다.
- `persistent-apps`를 잘못 쓰면 사용자의 Dock이 망가진다 → 쓰기 전 현재 배열을 `dock-backups/`에 저장(최근 10개).
- Dock 재시작 시 깜빡임 → 레이아웃이 실제로 다를 때만 쓴다.
- 독이 창을 가린다 → 자동 숨김, 대체 모드 기본값.
- 위젯이 항상 보이면 갱신이 늘어난다 → 독에 올린 위젯만, 숨겨져 있으면 제외.
