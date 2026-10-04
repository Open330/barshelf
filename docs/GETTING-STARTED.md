# BarShelf 시작하기

이 문서는 BarShelf을 설치하고, 3분 안에 첫 셸 위젯을 추가한 뒤, 번들 위젯을 둘러보기 위한 빠른 안내다.

관련 문서:

- URL로 위젯 설치: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 위젯 제작과 배포: [`docs/PUBLISHING.md`](PUBLISHING.md)
- 위젯 manifest 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)
- workflow DSL: [`docs/WORKFLOW.md`](WORKFLOW.md)
- Deno 스크립트 런타임: [`docs/SCRIPT-RUNTIME.md`](SCRIPT-RUNTIME.md)

<!-- 스크린샷 자리: 메뉴바에 표시된 BarShelf 아이콘과 열린 팝오버 -->

## 설치

전체 설치 방법(릴리스 zip, Gatekeeper 안내, barshelf CLI, 문제 해결)은 [`docs/INSTALL.md`](INSTALL.md)를 따른다. 요약:

### GitHub Releases (권장)

[Releases](https://github.com/Open330/barshelf/releases)에서 `BarShelf-<버전>-arm64.zip`을 받아 `/Applications`에 옮긴 뒤 일반 더블클릭으로 실행한다. v0.1.3은 Developer ID 서명·Apple 공증·티켓 스테이플과 Gatekeeper 배포 검사를 통과했다.

### 소스에서 수동 빌드

이 저장소에서 직접 빌드할 때는 Xcode 툴체인을 명시한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
open dist/BarShelf.app
```

`scripts/build_app.sh`는 SwiftPM product `barshelf-app`을 release로 빌드하고, `dist/BarShelf.app/Contents/MacOS/barshelf-app` 실행 파일과 `Contents/Info.plist`를 만든 뒤 `widgets/`를 앱 리소스로 복사한다. 같은 빌드에서 `dist/barshelf`와 `dist/bsf` CLI도 생성된다. 개발 중 검증은 다음 명령을 사용한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 코드 없이 위젯 만들기: Widget Builder

JSON을 직접 작성하지 않고도 위젯을 만들고 싶다면 in-app **Widget Builder**를 사용한다. BarShelf 창 사이드바의 **Create**(`Command-N`)에서 연다. 팝업의 ⋯ 메뉴 → **Add Widget…** 으로 갤러리를 연 뒤 **Create Widget**을 눌러도 된다.

3단계로 진행한다.

1. **Source** — 데이터 출처를 고른다: 셸 명령, HTTP JSON, 붙여넣은 JSON, 폴더 파일 목록, 고정 텍스트 중 하나. 명령은 **Test run**, HTTP는 **Fetch preview**로 출력 구조를 확인할 수 있다.
2. **Display** — 결과를 목록, 표, 값, 텍스트 중 어떤 모습으로 보여줄지 고른다. JSON이면 감지된 필드를 드롭다운에서 골라 매핑하고, 오른쪽 미리보기 패널에 실제 렌더링 결과가 즉시 반영된다.
3. **Details** — 이름, 아이콘, 페이지, 크기, 고급 새로고침 주기를 정하고 **Create**를 누르면 위젯이 바로 만들어진다.

코드를 한 줄도 쓰지 않고 셸 명령이나 폴더 기반 위젯을 몇 분 안에 만들 수 있는 가장 빠른 경로다. manifest와 workflow JSON을 직접 다루는 방법을 배우고 싶다면 아래 튜토리얼을 계속 읽는다.

<!-- 스크린샷 자리: Widget Builder의 Source / Display / Details 단계 -->

## 3분 위젯: Quick Hello

BarShelf은 개발 중 `./widgets/`를 먼저 보고, 사용자 설치 위젯은 `~/Library/Application Support/barshelf/widgets/`에서 읽는다. 아래 예제는 사용자 설치 경로에 새 위젯을 만든다.

```bash
install_root="$HOME/Library/Application Support/barshelf/widgets/dev.example.quick-hello"
mkdir -p "$install_root"
```

`widget.json`을 만든다.

```bash
cat > "$install_root/widget.json" <<'JSON'
{
  "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.quick-hello",
  "name": "Quick Hello",
  "version": "0.1.0",
  "icon": "hand.wave",
  "bucket": { "group": "Demo", "order": 11, "size": "S" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["./hello.sh"],
    "timeoutMs": 5000,
    "output": "viewtree"
  },
  "refresh": { "onOpen": true, "interval": 60, "staleAfterSec": 30 },
  "permissions": {
    "exec": [
      {
        "command": "./hello.sh",
        "allowedArgs": [[]],
        "maxOutputBytes": 65536,
        "sensitiveOutput": false
      }
    ],
    "network": [],
    "readPaths": [],
    "env": [],
    "keychain": false
  },
  "settings": []
}
JSON
```

실행 파일을 만든다.

```bash
cat > "$install_root/hello.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

now="$(date '+%H:%M:%S')"
second="$(date '+%S')"
progress="$(printf '0.%02d' "$((10#$second))")"

cat <<JSON
{
  "type": "vstack",
  "spacing": 8,
  "children": [
    { "type": "text", "role": "title", "text": "Quick Hello" },
    { "type": "text", "role": "body", "monospacedDigit": true, "text": "Rendered at ${now}" },
    { "type": "progress", "style": "linear", "value": ${progress}, "label": "Minute", "tint": "accent" },
    {
      "type": "button",
      "title": "Copy greeting",
      "icon": "doc.on.doc",
      "action": { "type": "copyText", "value": "Hello from BarShelf at ${now}", "toast": "Copied" }
    }
  ]
}
JSON
SH

chmod +x "$install_root/hello.sh"
```

앱이 실행 중이면 hot reload가 자동으로 반영된다. 팝오버를 열고 `Quick Hello` 권한 승인 카드에서 `Approve`를 누르면 위젯이 실행된다.

<!-- 스크린샷 자리: Quick Hello 위젯 권한 승인 카드 -->
<!-- 스크린샷 자리: Quick Hello 위젯이 렌더링된 상태 -->

## 번들 위젯

저장소의 `widgets/`에는 개발과 검증에 쓰는 번들 예제가 들어 있다.

| 위젯 | 위치 | 설명 |
| --- | --- | --- |
| Hello | [`widgets/hello`](../widgets/hello) | `./hello.sh`가 UINode JSON을 stdout으로 출력하는 가장 작은 exec 위젯이다. |
| aas Usage | [`widgets/aas-usage`](../widgets/aas-usage) | `aas usage --json` 결과를 `aas-usage` 내장 adapter로 렌더링한다. |
| OTP Codes | [`widgets/otpeek`](../widgets/otpeek) | `otpeek list --json`과 `otpeek code <id> --json`을 사용하고 Keychain 주입을 지원한다. |
| Script Clock | [`widgets/clock-script`](../widgets/clock-script) | Deno TypeScript 런타임과 `sdk/mod.ts`를 사용하는 script 위젯이다. |
| Recent Files | [`widgets/recent-files`](../widgets/recent-files) | `workflow.json`으로 `~/Downloads` 파일 목록, 썸네일, Finder 표시 액션, drag-out을 렌더링한다. |

## 기본 조작

- 메뉴바 아이콘을 클릭하면 팝오버가 열린다.
- 좌우 화살표, 하단 점, 두 손가락 가로 스와이프로 페이지를 전환한다. 헤더의 페이지 이름을 누르면 모든 페이지 목록이 나온다.
- 헤더의 ⋯ 메뉴에 선반 편집, 위젯 추가, 메뉴 막대, BarShelf 열기, 설정, 업데이트 확인, 종료가 있다. 메뉴바 아이콘 우클릭 메뉴도 같은 목록이다.
- `Command-1`부터 `Command-9`까지는 페이지로 바로 이동한다.
- `Command-F` 또는 타이핑으로 검색을 연다.
- `Command-R` 전체 새로고침, `Command-N` 위젯 만들기, `Command-E` 선반 편집, `Command-,` 설정, `Command-Q` 종료. 팝오버와 BarShelf 창 어디서나 동작한다.
- 위젯 카드의 톱니바퀴는 BarShelf 창에서 그 위젯의 설정을 연다. 카드 우클릭 메뉴에서 pin, refresh 등도 쓸 수 있다 (아래 "위젯 관리" 참고).
- `drag.filePath`가 있는 파일 노드는 Finder나 다른 앱으로 드래그할 수 있다.

### 데스크톱·알림 센터 위젯

BarShelf 위젯을 macOS 위젯으로도 띄울 수 있다. 데스크톱을 우클릭하거나 알림 센터
아래쪽의 **위젯 편집**에서 **BarShelf**를 찾아 놓은 뒤, 위젯을 우클릭 → **위젯 편집**에서
고른다.

- **위젯:** 보여 줄 BarShelf 위젯.
- **표시할 항목:** 그 위젯에서 보여 줄 부분만 여러 개 고를 수 있다. 사용량 위젯이면 계정
  카드나 Claude·Codex 묶음, System이면 CPU·메모리·디스크 줄, 파일 위젯이면 파일 하나씩이다.
  비워 두면 앞쪽 항목부터 보여 준다.
- **스타일:** 항목을 어떻게 그릴지. **자동**이 기본이고, 내용에 맞춰 고른다.
  - **큰 숫자:** 항목 하나의 값을 크게(예: 97% 남음)와 한 줄 설명, 막대.
  - **미터:** 이름·값·막대 줄. 작은 크기에서는 링 3개.
  - **목록:** 이름·값 줄. 큰 크기에서는 묶음 제목과 한 줄 설명이 붙는다.
  - **격자:** 파일 썸네일과 이름. 썸네일은 BarShelf가 작게 만들어 공유하고, 더 쓰지 않으면 지운다.

작게·중간·크게를 지원하고, 누르면 BarShelf 팝업에서 그 위젯이 열린다.

- macOS 위젯은 BarShelf가 마지막으로 읽은 값을 보여 준다. macOS가 위젯 갱신
  횟수를 제한하므로 최대 15분마다 바뀐다.
- 값이 오래되면(위젯 새로 고침 간격의 두 배, 최소 30분) 머리글에 주황색 시계와 경과 시간이
  나온다. 최신 값일 때는 시간을 표시하지 않는다.
- 스크롤, 드래그, 위젯 안의 버튼은 동작하지 않는다. 크기마다 보이는 항목 수가 정해져 있다.
- OTP 코드나 클립보드처럼 민감한 위젯은 목록에 나오지 않는다.

### 위젯 관리

**선반 편집**(`Command-E` 또는 ⋯ → Edit Shelf)을 켜면 모든 카드에 끌기 손잡이, 절반 너비/전체 너비 전환, 제거 버튼이 나타난다. 카드를 끌어 순서를 바꾸고, 하단 페이지 점 위에 놓으면 그 페이지로 옮겨진다. Esc나 Done으로 끝낸다.

위젯 카드를 우클릭하면 다음 메뉴가 나온다.

- **Pin**: 위젯을 상단에 고정해 페이지를 넘겨도 계속 보이게 한다 (최대 2개).
- **Settings…**: BarShelf 창에서 그 위젯의 설정을 연다.
- **Disable**: 삭제하지 않고 새로고침과 팝오버 노출만 끈다.
- **Move to Page**: 다른 페이지로 옮기거나 새 페이지 이름을 입력해 만든다.
- **Reveal in Finder**: 위젯이 설치된 디렉터리를 Finder로 연다.
- **Remove**: 확인 후 위젯 디렉터리와 관련 상태(pin, 설정, 새로고침 기록 등)를 모두 삭제한다.

BarShelf 창의 **Shelf**에서는 페이지가 열로 나란히 보인다. 위젯을 끌어 순서를 바꾸거나 다른 페이지로 옮기고, 선택하면 오른쪽 인스펙터에서 설정을 바꾼다. 설정은 바로 반영되며 `Command-Z`로 되돌린다.
