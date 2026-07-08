# MenuBucket

MenuBucket은 작은 네이티브 위젯을 macOS 메뉴바 팝오버에 모아 보여주는 앱이다. 위젯은 `widget.json` manifest로 실행 방식, 갱신 정책, 권한, Bucket 배치를 선언하고, 호스트는 JSON UINode view tree를 SwiftUI로 렌더링한다.

```
MenuBucket.app
├─ Layer 1: exec
│  └─ manifest가 선언한 명령을 no-shell argv로 실행하고 stdout JSON을 렌더링
├─ Layer 2: host services
│  └─ exec allowlist, storage, Keychain, 파일, 알림, audit log를 권한 게이트 뒤에서 제공
└─ Layer 3: script / workflow
   ├─ Deno TypeScript 위젯은 newline-delimited JSON-RPC로 호스트와 통신
   └─ workflow 위젯은 source -> transform -> render 선언형 파이프라인으로 실행
```

Swift 패키지는 UI와 무관한 모델/엔진을 `MenubucketCore`에 두고, AppKit/SwiftUI 렌더링, 메뉴바, 스케줄러, 런타임 실행은 `MenubucketApp`에 둔다.

## 빠른 시작

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
open dist/MenuBucket.app
```

개발 검증:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

첫 사용자 위젯을 3분 안에 만드는 절차는 [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md)를 따른다. 위젯은 개발 중 `./widgets/`, 사용자 설치 시 `~/Library/Application Support/menubucket/widgets/`에서 로드된다.

## 문서

| 문서 | 내용 |
| --- | --- |
| [`docs/GETTING-STARTED.md`](docs/GETTING-STARTED.md) | 설치, 첫 셸 위젯, 번들 위젯 둘러보기 |
| [`docs/INSTALLING-WIDGETS.md`](docs/INSTALLING-WIDGETS.md) | GitHub URL, `.zip`, `.mbw`, 딥링크, CLI 설치 |
| [`docs/PUBLISHING.md`](docs/PUBLISHING.md) | 제작자용 저장소 구조, README 설치 뱃지, mbk 워크플로, 레지스트리 등재 |
| [`docs/MBK.md`](docs/MBK.md) | `mbk` CLI 레퍼런스 — install/new/validate/pack/list |
| [`docs/REGISTRY.md`](docs/REGISTRY.md) | 레지스트리 `index.json` 규약, 등재 PR 절차, 셀프호스팅 |
| [`docs/WIDGET-SPEC.md`](docs/WIDGET-SPEC.md) | `widget.json` manifest와 UINode 스펙 |
| [`docs/WORKFLOW.md`](docs/WORKFLOW.md) | `workflow.json` DSL, `fs.directory`, 보간, `forEach` |
| [`docs/SCRIPT-RUNTIME.md`](docs/SCRIPT-RUNTIME.md) | Deno TypeScript JSON-RPC 런타임과 `sdk/mod.ts` |

스키마:

| 스키마 | 파일 |
| --- | --- |
| Manifest | [`schema/widget-0.1.json`](schema/widget-0.1.json) |
| UINode | [`schema/uinode-0.1.json`](schema/uinode-0.1.json) |
| Workflow | [`schema/workflow-0.1.json`](schema/workflow-0.1.json) |
| Registry | [`schema/registry-0.1.json`](schema/registry-0.1.json) |

## 번들 위젯 갤러리

| 위젯 | 위치 | 실행 계층 | 설명 |
| --- | --- | --- | --- |
| aas Usage | [`widgets/aas-usage`](widgets/aas-usage) | exec + adapter | `aas usage --json`을 `aas-usage` adapter로 변환해 사용량을 렌더링한다. |
| OTP Codes | [`widgets/otpeek`](widgets/otpeek) | exec + adapter | `otpeek list --json`, `otpeek code <id> --json`, Keychain 주입, countdown ring을 사용한다. |
| Script Clock | [`widgets/clock-script`](widgets/clock-script) | script | Deno TypeScript 프로세스가 `menubucket` SDK로 render/storage/timer를 호출한다. |
| Recent Files | [`widgets/recent-files`](widgets/recent-files) | workflow | `workflow.json`으로 `~/Downloads` 목록, file thumbnail/icon, reveal, drag-out을 렌더링한다. |

`widgets/hello`는 가장 작은 `output=viewtree` 셸 위젯 예제로, 시작 가이드의 Quick Hello 변형이 이 구조를 따른다.

## 빌드와 앱 번들

SwiftPM product 이름은 `menubucket`이다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

앱 번들은 다음 스크립트가 만든다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
```

결과는 `dist/MenuBucket.app`이다. 스크립트는 release product를 빌드하고, `Contents/MacOS/menubucket`을 복사하며, `scripts/Info.plist.template`에서 `Contents/Info.plist`를 렌더링하고, `widgets/`를 `Contents/Resources/widgets`로 복사한 뒤 ad-hoc codesign을 수행한다.

## 위젯 설치

URL 설치 v1은 다음 입력을 지원한다.

- GitHub 저장소: `https://github.com/{user}/{repo}` 또는 `https://github.com/{user}/{repo}/tree/{branch}[/{subdir}]`
- 직접 아카이브: `https://.../*.zip` 또는 `*.mbw`
- 딥링크: `menubucket://install?url=<percent-encoded-url>`

CLI 설치:

```bash
mbk install https://github.com/example/menubucket-widgets
# 또는 앱 바이너리의 인자 모드
MenuBucket.app/Contents/MacOS/menubucket install https://github.com/example/menubucket-widgets
```

자세한 설치 동작, 보안 제한, FAQ는 [`docs/INSTALLING-WIDGETS.md`](docs/INSTALLING-WIDGETS.md)에 있다.

## mbk CLI

`mbk`는 위젯 개발·배포·설치를 위한 독립 CLI다. 앱과 같은 Core 디코더와 설치 파이프라인을 GUI 없이 사용한다.

```bash
mbk new my-clock              # 템플릿 생성 (--kind exec|workflow|script) + 자동 validate
mbk validate ./my-clock       # widget.json(+workflow.json) 검증, 오류를 파일:필드 단위로 출력
mbk pack ./my-clock -o my-clock.mbw   # .mbw 패키징 (manifest.sha256 포함)
mbk install <url>             # GitHub/zip/.mbw/딥링크 설치 (권한 요약 후 확인, --yes로 생략)
mbk list                      # 설치된 위젯 나열 (id, name, version, kind)
```

exit 0 성공 / 1 실패, 오류는 stderr. 전체 레퍼런스는 [`docs/MBK.md`](docs/MBK.md)에 있다.

## 위젯 갤러리와 레지스트리

메뉴바 아이콘 우클릭 메뉴의 "Widget Gallery…"에서 레지스트리에 등재된 위젯을 검색(이름/태그)하고 카드에서 바로 설치할 수 있다. 카드에는 아이콘·설명·kind 배지·권한 칩이 표시되며, 권한 칩은 표시용 요약이고 실제 게이트는 설치 후 첫 실행 승인 카드다.

갤러리 데이터는 `registry/index.json` 인덱스에서 온다. 해석 순서는 env `MENUBUCKET_REGISTRY`(URL 또는 로컬 경로) → 기본 원격 레지스트리 → 번들 폴백이다. 인덱스 규약·등재 PR 절차·셀프호스팅은 [`docs/REGISTRY.md`](docs/REGISTRY.md), 스키마는 [`schema/registry-0.1.json`](schema/registry-0.1.json)에 있다.

## 위젯 제작 요약

각 위젯은 위젯 디렉터리의 `widget.json`에서 시작한다.

```json
{
  "$schema": "https://menubucket.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.clock",
  "name": "Clock",
  "version": "0.1.0",
  "icon": "clock",
  "bucket": { "group": "Demo", "order": 10, "size": "S" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["./clock.sh"],
    "timeoutMs": 5000,
    "output": "viewtree"
  },
  "refresh": { "onOpen": true, "interval": 60, "staleAfterSec": 60 },
  "permissions": {
    "exec": [
      {
        "command": "./clock.sh",
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
```

`source.command`는 shell 문자열이 아니라 argv 배열이다. 명령 실행과 `run` 액션은 `permissions.exec` allowlist와 매칭될 때만 실행된다.

## 스크립트 위젯

스크립트 위젯은 Deno TypeScript subprocess로 실행되고, 호스트와 newline-delimited JSON-RPC 2.0으로 통신한다. Deno가 없으면 script 위젯만 오류 카드가 표시되고 다른 위젯은 계속 동작한다.

```bash
brew install deno
```

예제는 [`widgets/clock-script`](widgets/clock-script), SDK는 [`sdk/mod.ts`](sdk/mod.ts), 런타임 계약은 [`docs/SCRIPT-RUNTIME.md`](docs/SCRIPT-RUNTIME.md)에 있다.

## 워크플로 위젯

워크플로 위젯은 manifest에서 `entry: { "kind": "workflow", "main": "workflow.json" }`를 선언한다. 호스트가 `sources`를 실행하고, `transforms`를 적용한 뒤, `${...}` 보간과 `forEach` 템플릿을 평가해 UINode를 만든다.

v1 source는 `exec`와 `fs.directory`를 지원한다. 파일 위젯은 `fileThumbnail`, `fileIcon`, `drag.filePath`, `openFile`, `revealFile` 액션을 함께 사용할 수 있다. 자세한 계약은 [`docs/WORKFLOW.md`](docs/WORKFLOW.md)에 있다.

## OTPeek 위젯

[`widgets/otpeek`](widgets/otpeek)은 `otpeek list --json`을 기본 source로 사용하고, 내장 `otpeek` adapter가 각 계정의 `otpeek code <id> --json`을 실행해 TOTP row를 렌더링한다. vault password를 Keychain에서 주입하려면 다음 명령을 사용한다.

```bash
security add-generic-password -s dev.menubucket -a otpeek-vault-password -w
```

manifest는 `permissions.keychain: true`, `OTPEEK_VAULT_PASSWORD` env 허용, `sensitiveOutput: true`를 선언해야 한다. OTP 복사 액션은 `copyText.clearAfterSec`로 클립보드 자동 삭제 시간을 지정할 수 있다.

## 조작

- 두 손가락 가로 스와이프, 좌우 버튼, 하단 점으로 Bucket 페이지를 전환한다.
- Left/Right Arrow로 페이지를 이동하고, `Command-1`부터 `Command-9`까지는 페이지로 바로 이동한다.
- `Command-F` 또는 타이핑으로 검색을 시작한다.
- 위젯 헤더 우클릭 메뉴에서 settings, pin/unpin, refresh를 실행한다.
- `bucket.pinned: true`인 위젯은 최초 상태에서 pinned 영역에 표시된다.
- `drag.filePath`가 있는 UINode는 Finder나 다른 앱으로 드래그할 수 있다.

## 로드맵

캐노니컬 구현 계획은 [`.context/plans/R01-merged.md`](.context/plans/R01-merged.md)에 있다. R05의 URL 설치 v1은 앱 내 URL 설치, 딥링크, CLI 설치를 같은 계약으로 맞추는 단계였고, R06은 그 위에 `mbk` 독립 CLI와 위젯 갤러리/레지스트리를 얹는 단계다.
