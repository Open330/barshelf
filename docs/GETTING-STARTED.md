# MenuBucket 시작하기

이 문서는 MenuBucket을 설치하고, 3분 안에 첫 셸 위젯을 추가한 뒤, 번들 위젯을 둘러보기 위한 빠른 안내다.

관련 문서:

- URL로 위젯 설치: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 위젯 제작과 배포: [`docs/PUBLISHING.md`](PUBLISHING.md)
- 위젯 manifest 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)
- workflow DSL: [`docs/WORKFLOW.md`](WORKFLOW.md)
- Deno 스크립트 런타임: [`docs/SCRIPT-RUNTIME.md`](SCRIPT-RUNTIME.md)

<!-- 스크린샷 자리: 메뉴바에 표시된 MenuBucket 아이콘과 열린 팝오버 -->

## 설치

전체 설치 방법(릴리스 zip, Gatekeeper 안내, mbk CLI, 문제 해결)은 [`docs/INSTALL.md`](INSTALL.md)를 따른다. 요약:

### GitHub Releases (권장)

[Releases](https://github.com/jiunbae/menubucket/releases)에서 `MenuBucket-<버전>-arm64.zip`을 받아 `/Applications`에 옮기고, 첫 실행은 **우클릭 → 열기**로 허용한다 (현재 릴리스는 공증 전 ad-hoc 서명 빌드 — Homebrew cask는 공증 이후 제공 예정).

### 소스에서 수동 빌드

이 저장소에서 직접 빌드할 때는 Xcode 툴체인을 명시한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
open dist/MenuBucket.app
```

`scripts/build_app.sh`는 SwiftPM product `menubucket`을 release로 빌드하고, `dist/MenuBucket.app/Contents/MacOS/menubucket` 실행 파일과 `Contents/Info.plist`를 만든 뒤 `widgets/`를 앱 리소스로 복사한다. 개발 중 검증은 다음 명령을 사용한다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 3분 위젯: Quick Hello

MenuBucket은 개발 중 `./widgets/`를 먼저 보고, 사용자 설치 위젯은 `~/Library/Application Support/menubucket/widgets/`에서 읽는다. 아래 예제는 사용자 설치 경로에 새 위젯을 만든다.

```bash
install_root="$HOME/Library/Application Support/menubucket/widgets/dev.example.quick-hello"
mkdir -p "$install_root"
```

`widget.json`을 만든다.

```bash
cat > "$install_root/widget.json" <<'JSON'
{
  "$schema": "https://menubucket.dev/schema/widget-0.1.json",
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
      "action": { "type": "copyText", "value": "Hello from MenuBucket at ${now}", "toast": "Copied" }
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
- 위젯 헤더 우클릭 메뉴에서 pin, settings, refresh를 사용할 수 있다.
- `drag.filePath`가 있는 파일 노드는 Finder나 다른 앱으로 드래그할 수 있다.
