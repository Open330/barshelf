# BarShelf 위젯 스펙 v0.1

이 문서는 `widgets/<name>/widget.json` 제작자를 위한 v0.1 스펙이다. Manifest는 위젯의 실행 방식, 권한, 갱신 정책, 버킷 배치를 선언하고, 출력은 UINode JSON view tree로 렌더링된다.

관련 문서:

- 시작하기: [`docs/GETTING-STARTED.md`](GETTING-STARTED.md)
- URL 설치: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 위젯 배포: [`docs/PUBLISHING.md`](PUBLISHING.md)
- Workflow DSL: [`docs/WORKFLOW.md`](WORKFLOW.md)
- 스크립트 런타임: [`docs/SCRIPT-RUNTIME.md`](SCRIPT-RUNTIME.md)

스키마:

- Manifest: [`schema/widget-0.1.json`](../schema/widget-0.1.json)
- UINode: [`schema/uinode-0.1.json`](../schema/uinode-0.1.json)
- Workflow: [`schema/workflow-0.1.json`](../schema/workflow-0.1.json), 참조: [`docs/WORKFLOW.md`](WORKFLOW.md)

## Manifest 기본형

```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.widget",
  "name": "Example",
  "version": "0.1.0",
  "icon": "sparkles",
  "bucket": { "group": "Demo", "order": 10, "size": "M", "pinned": false },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["example", "--json"],
    "discover": ["$EXAMPLE_BIN", "/opt/homebrew/bin/example", "PATH"],
    "timeoutMs": 20000,
    "output": "viewtree"
  },
  "refresh": {
    "onOpen": true,
    "interval": null,
    "staleAfterSec": 600,
    "deadlineField": null,
    "watchPaths": [],
    "runInBackground": false
  },
  "statusItem": { "mode": "none" },
  "permissions": {
    "exec": [
      {
        "command": "example",
        "allowedArgs": [["--json"]],
        "env": ["EXAMPLE_TOKEN"],
        "maxOutputBytes": 1048576,
        "sensitiveOutput": false
      }
    ],
    "network": [],
    "readPaths": [],
    "env": ["EXAMPLE_BIN"],
    "keychain": false
  },
  "settings": []
}
```

## Manifest 필드

| 필드 | 필수 | 설명 |
| --- | --- | --- |
| `$schema` | 아니오 | JSON Schema URL. 권장값은 `https://barshelf.dev/schema/widget-0.1.json`. |
| `schemaVersion` | 예 | v0.1은 `1`. |
| `id` | 예 | 전역에서 안정적인 위젯 ID. 예: `dev.barshelf.aas-usage`. |
| `name` | 예 | UI에 표시할 위젯 이름. |
| `version` | 아니오 | 위젯 패키지 버전. |
| `icon` | 예 | 위젯 기본 아이콘 이름. M1은 SF Symbol 스타일 이름을 우선 사용한다. |
| `bucket` | 예 | 팝오버 안의 그룹, 정렬, 크기. |
| `entry` | 예 | 실행 엔트리 종류. |
| `source` | exec 위젯은 예 | 실제 데이터/뷰트리 소스. Workflow와 script 위젯은 `entry.main`을 사용한다. |
| `refresh` | 예 | 갱신 트리거와 캐시 stale 정책. |
| `statusItem` | 아니오 | 메뉴바 status item 표시 정책. M1은 디코딩하고 `none`만 동작한다. |
| `permissions` | 아니오 | exec, env, 파일, storage, notifications, 네트워크, Keychain 권한 선언. |
| `settings` | 아니오 | 설정 UI를 자동 생성하기 위한 선언. 값은 workflow의 `${settings.key}`와 script context로 전달된다. |

### `bucket`

| 필드 | 설명 |
| --- | --- |
| `group` | 같은 그룹 이름끼리 한 버킷에 모인다. |
| `order` | 그룹 안 정렬 순서. 낮을수록 먼저 보인다. |
| `size` | `XS`, `S`, `M`, `L`. 렌더러가 권장 폭/높이에 매핑한다. |
| `pinned` | `true`이면 최초 설치 상태에서 팝오버 상단 pinned 영역에 배치한다. 사용자는 헤더 메뉴에서 토글할 수 있다. |

### `entry`

| `kind` | 동작 |
| --- | --- |
| `exec` | 지원. `source.kind=exec` 명령을 실행한다. |
| `script` | `entry.main`의 script runtime을 JSON-RPC subprocess로 실행한다. |
| `workflow` | `entry.main`의 `workflow.json`을 호스트 WorkflowEngine으로 실행한다. `main`은 필수다. |
| `builtin` | 호스트 내장 위젯을 가리키기 위한 예약 값이다. |

Workflow manifest 예:

```json
{
  "entry": { "kind": "workflow", "main": "workflow.json" }
}
```

Workflow DSL 상세 계약은 [`docs/WORKFLOW.md`](WORKFLOW.md)를 따른다.

### `source`

| 필드 | 설명 |
| --- | --- |
| `kind` | `exec`, `script`, `workflow`, `builtin`. M1 실행 지원은 `exec` 중심이다. |
| `command` | 실행할 argv 전체. 예: `["aas", "usage", "--json"]`. |
| `discover` | 실행 파일 탐색 후보. `$ENV`, `~`, 절대 경로, `PATH`를 사용할 수 있다. |
| `timeoutMs` | 명령 타임아웃. 없으면 호스트 기본값을 사용한다. |
| `output` | `viewtree`면 stdout을 UINode로 디코딩한다. `data`면 `adapter`가 UINode로 변환한다. |
| `adapter` | `output=data`일 때 사용할 내장 adapter 이름. 예: `aas-usage`, `otpeek`. |

### `refresh`

| 필드 | 설명 |
| --- | --- |
| `onOpen` | 팝오버가 열릴 때 stale 여부를 보고 갱신한다. |
| `interval` | 초 단위 반복 실행 주기. `null`이면 반복 실행하지 않는다. |
| `staleAfterSec` | 마지막 성공 snapshot이 stale로 간주되는 시간. |
| `deadlineField` | v0.1 예약 필드. M1에서는 adapter가 반환하는 `nextRefreshAtMs`가 deadline 갱신을 대체한다. |
| `watchPaths` | FSEvents 감시 경로 목록. 변경 이벤트는 250ms debounce 후 처리한다. |
| `runInBackground` | 팝오버가 닫힌 동안에도 interval 실행을 허용할지 여부. 닫힌 상태에서는 완화된 주기를 사용한다. |

### `statusItem`

```json
{
  "mode": "none",
  "icon": "gauge",
  "labelFrom": "$.status.label",
  "tooltipFrom": "$.status.tooltip"
}
```

| 필드 | 설명 |
| --- | --- |
| `mode` | `none`, `icon`, `text`, `dynamic`. M1은 `none`만 표시 동작을 보장한다. |
| `icon` | status item 아이콘. 현재 런타임에서는 SF Symbol 이름 문자열을 사용한다. |
| `labelFrom` | adapter/status 결과에서 label을 읽을 JSON path. |
| `tooltipFrom` | adapter/status 결과에서 tooltip을 읽을 JSON path. |

### `permissions`

| 필드 | 설명 |
| --- | --- |
| `exec` | 위젯이 실행할 수 있는 명령 allowlist. `source.command`와 선언적 `run` 액션이 이 목록과 매칭되어야 한다. |
| `network` | 예약. 네트워크 접근 선언용 배열. |
| `readPaths` | 예약. 파일 읽기 허용 경로 배열. |
| `files` | workflow `fs.directory`와 script host API가 사용할 파일 권한 선언. `id`, `access`, `prompt`, `bookmarkSetting`, `defaultPath`, `watch`를 둘 수 있다. |
| `storage` | script storage quota와 secret 허용 여부 선언. 스키마의 정식 형식은 `{ "maxBytes": 1048576, "secrets": false }`다. |
| `notifications` | `true`이면 script 런타임의 `host.notify.show` 요청을 허용한다. |
| `env` | 호스트가 읽거나 source 명령 탐색에 사용할 수 있는 환경 변수 이름. |
| `keychain` | Keychain 조회 허용 여부. otpeek vault password 주입에 사용한다. |

`permissions.exec[]`:

| 필드 | 설명 |
| --- | --- |
| `command` | 허용할 실행 파일 이름. 예: `aas`, `otpeek`. |
| `allowedArgs` | 허용할 argv tail 패턴 목록. 각 항목은 문자열 배열이고, `"*"`는 정확히 인자 1개를 매칭한다. |
| `env` | 이 명령에 주입할 수 있는 환경 변수 이름. |
| `maxOutputBytes` | stdout 최대 바이트 수. 초과 시 실패 처리한다. |
| `sensitiveOutput` | `true`면 stdout 로그와 디스크 캐시 저장을 금지한다. |

예:

```json
{
  "command": "otpeek",
  "allowedArgs": [["list", "--json"], ["code", "*", "--json"]],
  "env": ["OTPEEK_VAULT_PASSWORD"],
  "maxOutputBytes": 1048576,
  "sensitiveOutput": true
}
```

### `settings`

설정 선언은 위젯 헤더 우클릭 메뉴의 "Settings..." UI로 자동 변환된다. 저장된 값은 App Support에 유지되고, workflow에서는 `${settings.key}` 보간으로, script 위젯에서는 runtime context로 전달된다.

```json
[
  { "key": "limit", "title": "Maximum accounts", "type": "integer", "default": 6, "min": 1, "max": 12 },
  { "key": "favoritesOnly", "title": "Favorites only", "type": "boolean", "default": true },
  { "key": "folder", "title": "Folder", "type": "directory", "default": "~/Downloads", "permission": "recent-folder" },
  { "key": "viewMode", "title": "View mode", "type": "enum", "default": "grid", "options": ["grid", "list"] }
]
```

지원 타입은 `string`, `integer`, `boolean`, `enum`, `directory`다. `number`, `select`, `path`는 기존 manifest 호환을 위해 계속 디코딩할 수 있다.

## 팝오버 UX 계약

| 기능 | 계약 |
| --- | --- |
| Pin | `bucket.pinned: true`이면 위젯은 최초 상태에서 모든 페이지 상단의 pinned 영역에 들어간다. 사용자가 헤더 우클릭 메뉴에서 pin을 토글하면 저장된 사용자 설정이 manifest 기본값보다 우선한다. Pinned 영역은 최대 2행을 목표로 한다. |
| Search | 팝오버에서 `Command-F` 또는 타이핑 시작으로 검색 오버레이를 연다. 현재 snapshot 기준으로 위젯 이름, UINode `text`, 안정적 `id`를 매칭한다. 위/아래로 결과를 이동하고 Enter는 해당 노드의 action이 있으면 실행한다. |
| Settings | `settings[]` 선언으로 자동 폼을 만든다. 값 변경은 위젯 reload에 반영되고 workflow의 `${settings.key}` 보간에 사용된다. |
| Drag-out | UINode에 `drag: { "filePath": "/path/to/file" }`가 있으면 Finder와 다른 앱으로 파일을 드래그할 수 있다. |

## UINode 공통 필드

모든 노드는 다음 공통 필드를 가질 수 있다.

```json
{
  "id": "stable-row-id",
  "type": "text",
  "hidden": false,
  "accessibilityLabel": "Usage 72 percent",
  "accessibility": {
    "label": "Usage",
    "hint": "Shows current account usage",
    "value": "72 percent"
  },
  "style": {
    "padding": { "horizontal": 10, "vertical": 8 },
    "spacing": 8,
    "width": "fill",
    "height": 24,
    "alignment": "leading",
    "background": "secondary",
    "foreground": "primary"
  },
  "drag": { "filePath": "/Users/me/Downloads/report.pdf" }
}
```

반복 row/tile에는 안정적인 `id`를 권장한다. 호스트는 identity와 액션 routing에 이 값을 사용할 수 있다.
`drag.filePath`는 파일 row/tile 같은 반복 노드에 붙이면 가장 자연스럽다.

### 접근성 (`accessibilityLabel`)

`accessibilityLabel`은 모든 노드에 붙일 수 있는 옵셔널 문자열로, 그 노드의 VoiceOver 라벨을
명시적으로 지정한다. 지정하지 않으면 호스트의 기본 동작이 유지된다 — 순수 장식용 심볼은
VoiceOver에서 숨겨지고, 파일 썸네일은 파일명으로 읽힌다.

의미가 있는데 텍스트가 없는 요소(아이콘 버튼, 상태 심볼, 진행률 링 등)에 붙이면 좋다.

```json
{
  "type": "button",
  "icon": "trash",
  "accessibilityLabel": "Delete download",
  "action": { "type": "run", "command": ["rm", "/tmp/x"] }
}
```

```json
{
  "type": "image",
  "source": { "kind": "sfSymbol", "name": "wifi.slash" },
  "tint": "danger",
  "accessibilityLabel": "Offline"
}
```

라벨은 사람이 화면을 보지 않고도 이해할 수 있는 짧은 명사구가 좋다("Delete download",
"72% used"). 장식용 요소에는 굳이 붙이지 않는다.

## UINode 노드 예제

### `vstack`, `hstack`, `zstack`, `scroll`, `divider`, `spacer`

```json
{
  "type": "vstack",
  "spacing": 8,
  "children": [
    {
      "type": "hstack",
      "spacing": 6,
      "children": [
        { "type": "text", "role": "title", "text": "Agents" },
        { "type": "spacer" },
        { "type": "badge", "text": "Live", "tone": "good" }
      ]
    },
    { "type": "divider" },
    {
      "type": "scroll",
      "axis": "vertical",
      "child": { "type": "text", "text": "Scrollable content" }
    }
  ]
}
```

### `text`

```json
{
  "type": "text",
  "text": "personal.codex",
  "role": "caption",
  "lineLimit": 1,
  "truncation": "middle",
  "monospacedDigit": false
}
```

`role` 권장값은 `title`, `body`, `caption`, `code`, `label`이다. `code`와 숫자 UI에는 `monospacedDigit`를 같이 쓰면 흔들림이 적다.

### `image`

```json
{
  "type": "image",
  "source": { "kind": "sfSymbol", "name": "key.fill" },
  "size": 18,
  "tint": "secondary"
}
```

`source.kind`는 `sfSymbol`, `asset`, `fileIcon`, `fileThumbnail`, `url`, `data`를 사용할 수 있다.

파일 썸네일은 호스트 썸네일 서비스가 해석한다. `fileThumbnail`은 캐시 무효화를 위해 `path`와 `modifiedAt`을 함께 제공해야 하며, 실패 시 `fallback`으로 `fileIcon`을 둘 수 있다.

```json
{
  "type": "image",
  "source": {
    "kind": "fileThumbnail",
    "path": "/Users/me/Downloads/report.pdf",
    "modifiedAt": 1783442400000
  },
  "fallback": {
    "kind": "fileIcon",
    "path": "/Users/me/Downloads/report.pdf"
  },
  "size": { "width": 72, "height": 54 }
}
```

### `list`

```json
{
  "type": "list",
  "rowSpacing": 2,
  "virtualized": false,
  "items": [
    {
      "id": "row-1",
      "type": "hstack",
      "children": [
        { "type": "text", "text": "First item" },
        { "type": "spacer" },
        { "type": "badge", "text": "OK", "tone": "good" }
      ]
    }
  ],
  "empty": { "type": "empty", "icon": "tray", "title": "No items" }
}
```

작은 popover 목록은 `virtualized: false`가 기본 권장값이다. row 수가 많을 때만 `virtualized: true`를 사용한다.

### `grid`

```json
{
  "type": "grid",
  "columns": { "mode": "adaptive", "minWidth": 72, "maxColumns": 5 },
  "itemAspectRatio": 0.85,
  "items": [
    { "id": "tile-1", "type": "text", "text": "Tile" }
  ]
}
```

### `table`

```json
{
  "type": "table",
  "columns": [
    { "id": "account", "title": "Account", "width": "flex" },
    { "id": "usage", "title": "Usage", "width": 120 }
  ],
  "rows": [
    {
      "id": "codex/personal",
      "cells": {
        "account": { "type": "text", "text": "personal.codex" },
        "usage": { "type": "progress", "style": "linear", "value": 0.72, "label": "72%" }
      }
    }
  ]
}
```

### `progress`

정적 progress:

```json
{
  "type": "progress",
  "style": "linear",
  "value": 0.72,
  "label": "72%",
  "tint": "warning"
}
```

Countdown progress:

```json
{
  "type": "progress",
  "style": "ring",
  "countdown": { "from": 1783442400000, "until": 1783442430000 },
  "labelFrom": "remainingSeconds",
  "tintRules": [
    { "whenRemainingLtSeconds": 10, "tint": "danger" }
  ]
}
```

`countdown.from`과 `countdown.until`은 Unix epoch milliseconds이다. Countdown은 `value` 대신 사용할 수 있으며, 팝오버가 열려 있는 동안 호스트가 1초 tick으로 자체 갱신한다. 코드나 스크립트를 매초 다시 실행하지 않는다.

### `button`

```json
{
  "type": "button",
  "title": "Refresh",
  "icon": "arrow.clockwise",
  "role": "normal",
  "action": { "type": "refresh" }
}
```

### `section`, `badge`, `banner`, `empty`

```json
{
  "type": "section",
  "title": "Security",
  "children": [
    { "type": "badge", "text": "TOTP", "tone": "neutral" },
    { "type": "banner", "tone": "warning", "text": "Showing cached data" },
    { "type": "empty", "icon": "key.slash", "title": "No TOTP accounts", "subtitle": "Add accounts in otpeek." }
  ]
}
```

`section`은 card가 아니라 header가 있는 unframed group으로 렌더링된다.

### `switch`, `none`

```json
{
  "type": "switch",
  "value": "grid",
  "cases": {
    "grid": { "type": "grid", "items": [] },
    "list": { "type": "list", "items": [] }
  },
  "default": { "type": "none" }
}
```

`none`은 `EmptyView`에 해당한다.

## 액션

| 액션 | 필드 | 설명 |
| --- | --- | --- |
| `event` | `id`, `payload` | script/workflow runtime으로 이벤트를 전달하기 위한 예약 액션. |
| `copyText` | `value`, `toast`, `clearAfterSec` | 텍스트를 클립보드에 복사한다. `clearAfterSec`가 있으면 같은 clipboard changeCount일 때만 자동 삭제한다. |
| `openURL` | `url` | 기본 브라우저로 URL을 연다. |
| `openFile` | `path` | 파일을 기본 앱으로 연다. |
| `revealFile` | `path` | Finder에서 파일을 표시한다. |
| `run` | `command`, `thenRefresh` | manifest `permissions.exec` allowlist와 매칭되는 명령만 실행한다. |
| `refresh` | 없음 | 현재 위젯을 수동 갱신한다. |

`run` 예:

```json
{
  "type": "button",
  "title": "Switch to work",
  "action": {
    "type": "run",
    "command": ["aas", "switch", "work"],
    "thenRefresh": true
  }
}
```

위 액션은 다음 권한과 매칭될 때만 실행된다.

```json
{
  "permissions": {
    "exec": [
      {
        "command": "aas",
        "allowedArgs": [["switch", "*"]],
        "maxOutputBytes": 65536,
        "sensitiveOutput": false
      }
    ]
  }
}
```

## 갱신 모델

BarShelf은 cache-first로 동작한다. 팝오버가 열리면 마지막 성공 snapshot을 먼저 표시하고, stale이면 백그라운드 갱신을 시작한다. 갱신 실패 시 마지막 성공 snapshot을 유지하고 오류 banner/card를 표시한다.

| 트리거 | 설명 |
| --- | --- |
| `onOpen` | 팝오버가 열릴 때 `staleAfterSec` 기준으로 갱신한다. |
| `manual` | 사용자가 `refresh` 액션을 실행할 때 갱신한다. |
| `interval` | `refresh.interval` 초 단위로 갱신한다. 팝오버가 열려 있을 때 최소 5초 간격을 둔다. |
| `deadline` | adapter/viewtree 결과의 `nextRefreshAtMs` 시각에 정확히 1회 갱신한다. 팝오버가 닫히면 취소하고 다시 열릴 때 재평가한다. |
| `watch` | `refresh.watchPaths`를 FSEvents로 감시한다. 이벤트는 250ms debounce하고, 닫힌 상태에서는 pending으로 기록한 뒤 열릴 때 처리한다. |
| `wake` | sleep wake 후 stale 위젯을 일괄 갱신한다. |

공통 정책:

- 한 위젯의 동시 갱신은 하나로 coalesce한다.
- 연속 실패는 15초, 60초, 300초 cap의 지수 백오프로 완화한다.
- 성공하면 실패 백오프를 리셋한다.
- Countdown progress는 host tick으로만 갱신하므로 스크립트 재실행이 필요 없다.

## 민감 데이터 규칙

`permissions.exec[].sensitiveOutput=true`인 명령의 stdout은 로그에 남기지 않는다. Sensitive 위젯 snapshot은 디스크 캐시에 저장하지 않고 메모리에만 둔다.

OTP, access token, 계정별 사용량처럼 민감할 수 있는 값은 다음 원칙을 따른다.

- source와 adapter의 민감 stdout은 `sensitiveOutput: true`로 선언한다.
- OTP 복사 버튼에는 `copyText.clearAfterSec`를 지정한다.
- Keychain secret은 `permissions.keychain: true`와 command-level `env` 선언이 있을 때만 자식 프로세스 env로 주입한다.
- 클립보드 자동 삭제는 사용자가 그 사이 다른 내용을 복사하지 않았을 때만 수행한다.

## 예제 1: hello viewtree

가장 단순한 위젯은 `output=viewtree` 명령이 UINode JSON을 stdout으로 출력한다.

저장소의 실제 샘플은 [`widgets/hello/widget.json`](../widgets/hello/widget.json)과 [`widgets/hello/hello.sh`](../widgets/hello/hello.sh)에 있다. 설치용 위젯에서는 아래처럼 `permissions.exec` allowlist를 명시하는 것을 권장한다.

```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.barshelf.hello",
  "name": "Hello",
  "version": "0.1.0",
  "icon": "hand.wave",
  "bucket": { "group": "Demo", "order": 10, "size": "S" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["./hello.sh"],
    "timeoutMs": 5000,
    "output": "viewtree"
  },
  "refresh": {
    "onOpen": true,
    "interval": 60,
    "staleAfterSec": 60,
    "deadlineField": null,
    "watchPaths": [],
    "runInBackground": false
  },
  "statusItem": { "mode": "none" },
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
```

stdout 예:

```json
{
  "type": "vstack",
  "spacing": 8,
  "children": [
    { "type": "text", "role": "title", "text": "Hello BarShelf" },
    { "type": "text", "role": "caption", "text": "Rendered from a JSON view tree." },
    {
      "type": "button",
      "title": "Copy greeting",
      "action": { "type": "copyText", "value": "Hello BarShelf", "toast": "Copied" }
    }
  ]
}
```

## 예제 2: aas data + adapter

`aas usage --json`은 raw data를 출력하고, 내장 `aas-usage` adapter가 UINode로 변환한다.

```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.barshelf.aas-usage",
  "name": "aas Usage",
  "version": "0.1.0",
  "icon": "gauge",
  "bucket": { "group": "Agents", "order": 20, "size": "M" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["aas", "usage", "--json"],
    "discover": ["$AAS_BIN", "~/.cargo/bin/aas", "/opt/homebrew/bin/aas", "/usr/local/bin/aas", "PATH"],
    "timeoutMs": 25000,
    "output": "data",
    "adapter": "aas-usage"
  },
  "refresh": {
    "onOpen": true,
    "interval": null,
    "staleAfterSec": 600,
    "deadlineField": null,
    "watchPaths": [],
    "runInBackground": false
  },
  "statusItem": { "mode": "none" },
  "permissions": {
    "exec": [
      {
        "command": "aas",
        "allowedArgs": [["usage", "--json"], ["switch", "*"]],
        "env": [],
        "maxOutputBytes": 1048576,
        "sensitiveOutput": false
      }
    ],
    "network": [],
    "readPaths": [],
    "env": ["AAS_BIN"],
    "keychain": false
  },
  "settings": []
}
```

워크스루:

1. 호스트가 `discover` 순서대로 `aas` 실행 파일을 찾는다.
2. `source.command`가 `permissions.exec`의 `command=aas`, `allowedArgs=["usage","--json"]`와 매칭되는지 확인한다.
3. stdout data를 `aas-usage` adapter로 넘긴다.
4. adapter가 usage table/progress UINode와 선택적 `statusText`를 반환한다.
5. 별도 버튼에서 `run` 액션을 추가하려면 해당 argv를 `permissions.exec[].allowedArgs`에 명시해야 한다. 예를 들어 `["aas", "switch", "work"]`는 `["switch", "*"]` 패턴이 있을 때만 실행되고, `thenRefresh`가 `true`면 다시 갱신한다.

## 예제 3: otpeek

otpeek 위젯은 TOTP 계정을 조회한 뒤 각 계정의 코드를 병렬로 가져오고, countdown ring은 host가 매초 갱신한다.

```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.barshelf.otpeek",
  "name": "OTPeek",
  "version": "0.1.0",
  "icon": "lock.shield",
  "bucket": { "group": "Security", "order": 10, "size": "M" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["otpeek", "list", "--json"],
    "discover": ["$OTPEEK_BIN", "~/.cargo/bin/otpeek", "/opt/homebrew/bin/otpeek", "/usr/local/bin/otpeek", "PATH"],
    "timeoutMs": 8000,
    "output": "data",
    "adapter": "otpeek"
  },
  "refresh": {
    "onOpen": true,
    "interval": null,
    "staleAfterSec": 35,
    "deadlineField": null,
    "watchPaths": [],
    "runInBackground": false
  },
  "statusItem": { "mode": "none" },
  "permissions": {
    "exec": [
      {
        "command": "otpeek",
        "allowedArgs": [["list", "--json"], ["code", "*", "--json"]],
        "env": ["OTPEEK_VAULT_PASSWORD"],
        "maxOutputBytes": 1048576,
        "sensitiveOutput": true
      }
    ],
    "network": [],
    "readPaths": [],
    "env": ["OTPEEK_BIN"],
    "keychain": true
  },
  "settings": [
    { "key": "limit", "title": "Maximum accounts", "type": "integer", "default": 6, "min": 1, "max": 12 },
    { "key": "favoritesOnly", "title": "Favorites only", "type": "boolean", "default": true }
  ]
}
```

Keychain에 vault password를 저장하려면 다음 명령을 사용한다.

```bash
security add-generic-password -s dev.barshelf -a otpeek-vault-password -w
```

adapter가 생성하는 row 예:

```json
{
  "id": "github:me@example.com",
  "type": "hstack",
  "spacing": 10,
  "children": [
    { "type": "image", "source": { "kind": "sfSymbol", "name": "key.fill" }, "size": 18, "tint": "secondary" },
    {
      "type": "vstack",
      "spacing": 2,
      "style": { "width": "fill" },
      "children": [
        { "type": "text", "role": "body", "lineLimit": 1, "text": "GitHub" },
        { "type": "text", "role": "caption", "lineLimit": 1, "truncation": "middle", "text": "me@example.com" }
      ]
    },
    {
      "type": "progress",
      "style": "ring",
      "countdown": { "from": 1783442400000, "until": 1783442430000 },
      "labelFrom": "remainingSeconds",
      "tintRules": [{ "whenRemainingLtSeconds": 10, "tint": "danger" }]
    },
    { "type": "text", "role": "code", "monospacedDigit": true, "text": "728 419" },
    {
      "type": "button",
      "icon": "doc.on.doc",
      "tooltip": "Copy code",
      "action": { "type": "copyText", "value": "728419", "toast": "Copied", "clearAfterSec": 30 }
    }
  ]
}
```

워크스루:

1. 호스트가 `$OTPEEK_BIN`, `~/.cargo/bin/otpeek`, Homebrew 경로, `PATH` 순서로 `otpeek`을 찾는다.
2. `otpeek list --json` stdout은 secret을 포함할 수 있으므로 `sensitiveOutput: true`로 취급한다.
3. `permissions.keychain=true`이면 `dev.barshelf` service의 `otpeek-vault-password` account를 조회하고, 값이 있으면 `OTPEEK_VAULT_PASSWORD` env로 주입한다.
4. adapter는 TOTP 계정만 필터링하고 각 계정에 대해 `otpeek code <id> --json`을 병렬 실행한다.
5. row는 issuer/accountName, countdown ring, 그룹핑된 코드, `copyText.clearAfterSec=30` 액션을 포함한다.
6. adapter는 `nextRefreshAtMs = min(validUntil) + 250`을 반환해 다음 TOTP boundary에서 정확히 다시 실행되게 한다.
7. otpeek 미설치 또는 vault password 오류는 다른 위젯에 영향을 주지 않고 오류 카드로 표시한다.
