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

전체 설치 방법(릴리스 zip, Gatekeeper 안내, mbk CLI, 문제 해결)은 [`docs/INSTALL.md`](INSTALL.md)를 따른다. 요약:

### GitHub Releases (권장)

[Releases](https://github.com/Open330/barshelf/releases)에서 `BarShelf-<버전>-arm64.zip`을 받아 `/Applications`에 옮기고, 첫 실행은 **우클릭 → 열기**로 허용한다 (현재 릴리스는 공증 전 ad-hoc 서명 빌드 — Homebrew cask는 공증 이후 제공 예정).

### 소스에서 수동 빌드

이 저장소에서 직접 빌드할 때는 Xcode 툴체인을 명시한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
open dist/BarShelf.app
```

`scripts/build_app.sh`는 SwiftPM product `menubucket`을 release로 빌드하고, `dist/BarShelf.app/Contents/MacOS/barshelf` 실행 파일과 `Contents/Info.plist`를 만든 뒤 `widgets/`를 앱 리소스로 복사한다. 개발 중 검증은 다음 명령을 사용한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 코드 없이 위젯 만들기: Widget Builder

JSON을 직접 작성하지 않고도 위젯을 만들고 싶다면 in-app **Widget Builder**를 사용한다. 메뉴바의 BarShelf 아이콘을 우클릭하고 **Create Widget…**을 선택하면 열린다.

3단계로 진행한다.

1. **Source** — 데이터 출처를 고른다: 셸 명령 실행, 폴더의 파일 목록, 고정 텍스트 중 하나. 명령을 골랐다면 **Test run** 버튼으로 즉시 실행해 출력이 JSON 배열/객체인지 일반 텍스트인지 바로 확인할 수 있다.
2. **Display** — 결과를 목록, 표, 값, 텍스트 중 어떤 모습으로 보여줄지 고른다. 명령 출력이 JSON이면 감지된 필드를 드롭다운에서 골라 매핑하고, 오른쪽 미리보기 패널에 실제 렌더링 결과가 즉시 반영된다.
3. **Details** — 이름, 아이콘, Bucket, 크기, 새로고침 주기를 정하고 **Create**를 누르면 위젯이 바로 만들어진다.

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
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
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
- 좌우 화살표, 하단 점, 두 손가락 가로 스와이프로 Bucket 페이지를 전환한다.
- `Command-1`부터 `Command-9`까지는 페이지로 바로 이동한다.
- `Command-F` 또는 타이핑으로 검색을 연다.
- 위젯 카드 우클릭 메뉴에서 pin, settings, refresh 등을 사용할 수 있다 (자세한 목록은 아래 "위젯 관리" 참고).
- `drag.filePath`가 있는 파일 노드는 Finder나 다른 앱으로 드래그할 수 있다.

### 위젯 관리

위젯 카드를 우클릭하면 다음 메뉴가 나온다.

- **Pin**: 위젯을 상단에 고정해 페이지를 넘겨도 계속 보이게 한다.
- **Settings**: 위젯별 설정 화면을 연다.
- **Disable**: 삭제하지 않고 새로고침과 팝오버 노출만 끈다.
- **Move to Bucket**: 다른 Bucket으로 옮기거나 새 Bucket 이름을 입력해 만든다.
- **Reveal in Finder**: 위젯이 설치된 디렉터리를 Finder로 연다.
- **Remove**: 확인 후 위젯 디렉터리와 관련 상태(pin, 설정, 새로고침 기록 등)를 모두 삭제한다.

메뉴바 아이콘 우클릭 → **Settings**로 여는 설정 창의 **Widgets** 탭에서도 전체 위젯을 한 목록으로 보면서 활성화/비활성화, Bucket 이동, 순서 변경, 삭제를 관리할 수 있다.
