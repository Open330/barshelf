# BarShelf — macOS 위젯(WidgetKit) 지원 기획 (R14)

> 작성일: 2026-10-03 | 기준: v0.5.1 (`0b21300`)
> 한 줄 요약: **BarShelf 위젯 하나를 골라 데스크톱·알림 센터에 띄운다.** 데이터는 BarShelf가
> 만들고, macOS 위젯은 그 마지막 결과를 보여 주기만 한다.

---

## 0. 결정할 것

| # | 질문 | 추천 |
|---|---|---|
| 1 | 확장(.appex) 빌드 방식 | 확장만 담은 **최소 Xcode 프로젝트**를 커밋하고 `build_app.sh`가 `xcodebuild`로 빌드. 위젯을 고르는 설정(AppIntentConfiguration)에 필요한 `Metadata.appintents`를 Xcode가 만들어 주기 때문 |
| 2 | 첫 범위 | **읽기 전용 미러 한 종류**: 사용자가 BarShelf 위젯 하나를 골라 Small/Medium/Large로 표시. 탭하면 BarShelf에서 그 위젯을 연다 |
| 3 | 민감한 위젯(OTP, 클립보드) | **위젯 목록에서 제외**. 공유 폴더에 비밀번호나 코드를 쓰지 않는다 |
| 4 | 갱신 주기 | 앱의 값이 바뀔 때 다시 그리되 **최소 15분 간격**. macOS가 하루 40–70회로 제한한다 |
| 5 | 배포 | 별도 **0.6.0**. 0.5.1 정식 공개 후 시작 |

---

## 1. 가능 여부 (조사 결과)

- **빌드:** `swiftc -application-extension -Xlinker -e -Xlinker _NSExtensionMain`으로 SwiftPM만 써서 확장을 링크할 수 있음을
  확인했다(서명·등록은 아직 안 함). 다만 위젯 설정 화면용 `Metadata.appintents`는 Xcode의 비공개 처리기가 만들어서,
  손으로 흉내 내기는 깨지기 쉽다 → 확장만 Xcode 프로젝트로.
- **샌드박스:** 위젯 확장은 샌드박스가 필수(아니면 위젯 갤러리에 안 나옴). 그래서 확장은 명령 실행도, BarShelf 데이터 폴더 읽기도 못 한다.
- **데이터 공유:** App Group. macOS 26에서는 그룹 ID가 **팀 ID로 시작**해야 프로필·경고 없이 동작한다
  (`group.` 형식은 거부되고 위젯이 종료됨). → `728FW73BS8.com.barshelf.shared`.
- **서명:** 지금 `build_app.sh`는 `codesign --deep`으로 앱 권한을 모든 하위 코드에 덮어씌운다.
  확장을 넣으면 **안쪽부터 따로 서명**해야 한다(확장 → 앱, `--deep` 제거).
- **업데이터:** `CodeSignature`가 이미 하위 코드까지 엄격히 검증하므로, 확장 서명이 틀리면 업데이트가 거부된다. 변경 불필요.
- **Homebrew:** cask의 `zap`에 그룹 컨테이너 추가 정도.

## 2. 위젯에서 되는 것과 안 되는 것

| 구분 | BarShelf 노드 | 위젯에서 |
|---|---|---|
| 그대로 | vstack/hstack/zstack, text, divider, spacer, badge, banner, card, section, progress, SF Symbol·모노그램 이미지 | 같은 모양 |
| 대체 | scroll → 잘라서 표시, list → 크기별 앞쪽 N행, grid → 스크롤 없는 격자, URL·파일 썸네일 → 앱이 PNG로 저장해 전달, 브랜드 아이콘 → BrandGlyph 이식, 버튼 → `barshelf://` 링크 | 축소 |
| 불가 | 드래그, 위젯 안에서 복사·명령 실행, 검색 | 생략 |

- 카운트다운은 `Text(timerInterval:)`로 매초 움직인다(갱신 횟수를 쓰지 않음).
- 데스크톱 위젯은 포커스가 없을 때 흐리게(단색) 그려진다. 상태를 색만으로 나타내지 말고 아이콘·글자를 같이 쓴다(이미 R13 원칙).

## 3. 구조

```
BarShelf.app (호스트, 샌드박스 아님)
 ├─ 위젯 새로고침 → WidgetSnapshot
 ├─ 공유 컨테이너에 기록 (728FW73BS8.com.barshelf.shared)
 │    index.json        : 고를 수 있는 위젯 목록 (민감한 위젯 제외)
 │    snapshots/<id>.json : 마지막 UINode 트리 (민감 정보 제거본)
 │    images/<hash>.png  : 썸네일·원격 이미지
 └─ 값이 바뀌면 WidgetCenter.reloadTimelines (종류별, 15분 제한)

Contents/PlugIns/BarShelfWidgets.appex (샌드박스)
 ├─ AppIntentConfiguration: index.json에서 위젯 고르기
 ├─ TimelineProvider: snapshots/<id>.json 읽기
 └─ WidgetTreeRenderer: 위젯용으로 줄인 렌더러
```

- 렌더러는 지금 앱 쪽(`ViewTreeRenderer`, AppKit 의존)에 있어서, 확장용으로 작은 렌더러를 따로 둔다.
  공통 부분(레이아웃 규칙, 색·토큰)은 Core 또는 공용 소스로 뺀다.
- 위젯 종류 이름(kind)은 한 번 정하면 바꾸지 않는다. 사용자가 배치한 위젯이 이 이름에 묶인다.

## 4. 단계 (PR 단위, 약 2주)

1. **공유 컨테이너 (1–2일):** Core에 공유 스냅샷 기록기, 민감 위젯 제외·제거본 규칙, 호스트 entitlement. 테스트.
2. **확장 뼈대와 빌드 (2–3일, 가장 위험):** 최소 Xcode 프로젝트, `build_app.sh`에서 빌드·`PlugIns/` 배치,
   안쪽부터 서명(`--deep` 제거), `verify-release.sh`에 확장 서명·샌드박스·그룹 검사 추가,
   `pluginkit -m -p com.apple.widgetkit-extension`으로 등록 확인. 서명된 빌드로 이 Mac에서 실제 표시 확인.
3. **위젯 렌더러 (3–4일):** 위 표의 노드, Small/Medium/Large, 흐린 모드.
4. **설정과 갱신 (2–3일):** 위젯 고르기, 15분 제한 갱신, 탭 → `barshelf://` 딥링크, 대체 표시.
5. **릴리스 준비 (1일):** 업데이트 리허설(이전 서명 빌드에서 교체 후 위젯 재등록 확인), 문서, 0.6.0.

## 5. 위험

- App Group 설정이 틀리면 위젯이 **조용히** 실패한다 → 2단계에서 서명된 빌드로 바로 확인.
- `--deep` 제거로 서명 방식이 바뀐다 → 기존 릴리스 검사 전부 통과해야 함.
- 사용자는 실시간을 기대할 수 있다 → 위젯 설정에 "마지막 갱신 시각"을 항상 표시.
- 렌더러가 둘이 된다 → 위젯 렌더러는 노드 일부만, 공통 규칙은 한 곳에.
- 업데이트로 앱이 바뀐 뒤 macOS가 확장을 다시 등록하는 시점이 확인되지 않음 → 5단계 리허설.
