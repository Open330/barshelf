# menubucket R01 - 기술 사양: 스크립팅 엔진과 플러그인 API

작성 관점: Codex / Technical Specification  
대상 프로젝트: `menubucket` - scriptable, customizable macOS menu bar widget platform

## 0. 결론 요약

menubucket의 v1 구조는 다음 결정을 기준으로 잡는다.

1. 호스트는 AppKit `NSStatusItem + NSPopover + NSHostingController`로 구현한다.
   - `file-stack`의 `NSStatusItem`/`NSPopover` 방식처럼 팝오버 위치, 우클릭 메뉴, 열림/닫힘 생명주기를 직접 제어한다.
   - `MenuBarExtra`는 `otpeek`, `aas-bar`처럼 빠르게 네이티브 팝오버를 만들기 좋지만, menubucket의 다중 위젯 페이지, swipe pagination, 상태 아이템 동작 제어에는 AppKit 방식이 더 안정적이다.
2. 위젯 UI는 HTML/WebView가 아니라 선언형 UI 트리(`UINode`)를 SwiftUI/AppKit 네이티브 뷰로 렌더링한다.
   - 스크립트는 "무엇을 보여줄지"만 JSON으로 선언한다.
   - 렌더링, diff, 접근성, 타이머 기반 progress, 썸네일 캐시는 호스트가 담당한다.
3. v1 스크립트 런타임은 "subprocess Deno TypeScript"를 1급 지원으로 둔다.
   - Python/Lua는 같은 JSON-RPC 프로토콜을 구현하는 별도 runner로 확장한다.
   - 임베디드 JavaScriptCore/Lua는 v1에서 사용하지 않는다. 제3자 코드를 앱 프로세스 안에서 실행하지 않는 것이 핵심 보안 경계다.
4. declarative workflow는 스크립트 없이 호스트가 직접 실행한다.
   - iOS Shortcuts처럼 `source -> transform -> render` 단계로 구성한다.
   - 파일 목록, CLI JSON, HTTP JSON처럼 반복 패턴이 명확한 위젯은 workflow로 충분해야 한다.
5. 기존 CLI는 데이터 소스다.
   - `aas usage --json`은 이미 좋은 기계 판독 계약이다.
   - `otpeek`은 현재 `list --json`이 secret까지 포함하므로, menubucket용으로는 장기적으로 `otpeek widget --json` 또는 `otpeek list --public-json`을 추가하는 것이 맞다. v1 예제는 기존 CLI만으로 가능한 fallback을 보이되 민감 출력으로 취급한다.
   - `file-stack`은 CLI보다 네이티브 파일 시스템/FSEvents/thumbnail cache 코드가 핵심이므로 workflow의 `fs.directory` source로 흡수한다.

## 1. 참고 코드베이스에서 가져올 설계 맥락

### 1.1 file-stack / Stashbar

읽은 핵심 파일:

- `/Users/jiun/workspace/file-stack/Sources/FileStackApp/main.swift`
- `/Users/jiun/workspace/file-stack/Sources/FileStackApp/FileStackController.swift`
- `/Users/jiun/workspace/file-stack/Sources/FileStackApp/DirectoryWatcher.swift`
- `/Users/jiun/workspace/file-stack/Sources/FileStackApp/ThumbnailCache.swift`
- `/Users/jiun/workspace/file-stack/Sources/FileStackApp/DiskThumbnailCache.swift`
- `/Users/jiun/workspace/file-stack/Sources/FileStackCore/Models.swift`

menubucket에 반영할 점:

- `NSStatusItem` 버튼 클릭으로 팝오버를 열고, 우클릭은 `NSMenu`로 분기한다.
- 팝오버가 열렸을 때만 무거운 reload/prefetch를 수행한다. `FileStackController.setInterfaceActive(_:)`와 pending reload 큐가 좋은 기준이다.
- 파일 watcher는 FSEvents를 사용하고, event는 main queue로 다시 전달한다.
- 썸네일은 `NSCache` + disk cache + in-flight coalescing이 필요하다.
- 파일 UI는 SwiftUI만으로 충분하지 않을 수 있다. 많은 thumbnail grid는 AppKit `NSCollectionView` bridge를 허용한다.

### 1.2 otpeek

읽은 핵심 파일:

- `/Users/jiun/workspace/otpeek/docs/ARCHITECTURE.md`
- `/Users/jiun/workspace/otpeek/apple/Otpeek/OtpeekApp.swift`
- `/Users/jiun/workspace/otpeek/apple/Otpeek/Views/MenuBarView.swift`
- `/Users/jiun/workspace/otpeek/apple/Shared/OtpStore.swift`
- `/Users/jiun/workspace/otpeek/apple/Shared/OtpGenerator.swift`
- `/Users/jiun/workspace/otpeek/apple/Shared/SharedViews.swift`
- `/Users/jiun/workspace/otpeek/apple/Shared/VaultAccess.swift`
- `/Users/jiun/workspace/otpeek/core/crates/otpeek-cli/src/main.rs`

menubucket에 반영할 점:

- 비즈니스 로직과 UI shell을 분리한다. OTP 계산처럼 민감하거나 정확성이 중요한 로직은 스크립트에서 재구현하지 않고 기존 core/CLI가 제공해야 한다.
- OTP row는 전체 목록을 매초 다시 그리지 않는다. `TimelineView`로 row 내부 countdown만 1초 주기로 갱신하고, 새 코드가 필요할 때만 데이터 refresh를 수행한다.
- 프로세스 간 변경 알림은 Darwin notification 같은 OS primitive를 붙일 수 있다. menubucket v1에서는 일반 플러그인 API에는 노출하지 않되, 향후 `watch.darwinNotification` capability로 확장 가능하다.

### 1.3 aas / aas-bar

읽은 핵심 파일:

- `/Users/jiun/workspace-open330/aas/README.md`
- `/Users/jiun/workspace-open330/aas/docs/DESIGN-aas-bar.md`
- `/Users/jiun/workspace-open330/aas/apps/aas-bar/Sources/AasBar/AasBarApp.swift`
- `/Users/jiun/workspace-open330/aas/apps/aas-bar/Sources/AasBar/Model.swift`
- `/Users/jiun/workspace-open330/aas/apps/aas-bar/Sources/AasBar/PopoverView.swift`
- `/Users/jiun/workspace-open330/aas/crates/aas-cli/src/main.rs`
- `/Users/jiun/workspace-open330/aas/crates/aas-providers/src/snapshot.rs`
- `/Users/jiun/workspace-open330/aas/crates/aas-core/src/backoff.rs`

menubucket에 반영할 점:

- `aas usage --json`은 menubucket이 원하는 CLI 데이터 소스 계약의 좋은 예다.
- GUI 앱은 PATH가 빈약하므로 `$AAS_BIN`, `~/.cargo/bin`, Homebrew 경로, PATH fallback 순서가 필요하다.
- usage API는 rate limit이 있으므로 자동 polling보다 cache-first + manual refresh가 맞다.
- subprocess 실행은 main thread 밖에서 수행하고 stdout/stderr를 모두 drain해야 deadlock을 피한다.

## 2. 시스템 아키텍처

```text
MenuBucket.app
  AppKitHost
    StatusItemController
    PopoverWindowController
    GlobalEventMonitor
  WidgetRuntime
    WidgetCatalog
    PermissionStore
    Scheduler
    RuntimeSupervisor
    JsonRpcBridge
    WorkflowEngine
  DataServices
    ExecService
    HttpService
    StorageService
    SecretStore(Keychain)
    FileSourceService(FSEvents)
    ThumbnailService(file-stack style)
    NotificationService
  NativeRenderer
    UINodeDecoder
    SwiftUIRenderer
    AppKitGridBridge
    ActionRouter
  Persistence
    InstalledWidgetDB
    WidgetCache
    Logs
```

원칙:

- 스크립트 프로세스는 직접 network/run/write 권한을 갖지 않는다.
- 모든 외부 I/O는 host API를 통해 수행한다.
- 위젯이 render한 마지막 정상 UI snapshot은 cache한다.
- 팝오버가 닫혀 있으면 UI tick과 thumbnail prefetch를 멈춘다.
- 스케줄러는 foreground, background, manual trigger를 구분한다.

## 3. 위젯 패키지와 manifest schema

### 3.1 기본 패키지 형태

권장 기본은 directory bundle이다.

```text
MyWidget.mbwidget/
  menubucket.widget.yaml
  index.ts                 # script widget인 경우
  workflow.yaml            # declarative workflow인 경우
  assets/
  vendor/                  # vendored TS deps, optional
  deno.lock
  README.md
```

간단한 위젯은 single-file도 허용한다.

```text
aas-usage.mb.ts            # YAML frontmatter + TypeScript body
recent-files.mbw.yaml      # manifest + workflow를 한 파일에 포함
```

배포 단위는 `.mbw` zip archive다. 내부는 directory bundle과 동일하며 `manifest.sha256`, `signature.ed25519`를 추가할 수 있다.

### 3.2 `menubucket.widget.yaml` schema v1

```yaml
schemaVersion: 1
kind: widget

id: reverse.dns.id
name: Human Name
version: 0.1.0
author:
  name: Author Name
  url: https://example.com
description: Short description

requires:
  host: ">=0.1.0"
  api: "1.x"
  macOS: ">=13.0"

entry:
  kind: script              # script | workflow
  runtime: deno-ts@1        # deno-ts@1 | python@1 | lua@1 | workflow@1
  main: index.ts

bucket:
  group: Default
  order: 100
  page: auto                # auto | full | compact
  preferredSize:
    width: 360
    minHeight: 120
    maxHeight: 420

statusItem:
  mode: icon                # icon | text | iconAndText | dynamic
  icon:
    type: sfSymbol
    name: square.grid.2x2
  labelFrom: "$.status.label"
  tooltipFrom: "$.status.tooltip"

refresh:
  onOpen: true
  onInstall: true
  interval: null            # e.g. 5m; null = no automatic interval
  minInterval: 5s
  staleAfter: 5m
  timeout: 20s
  jitter: 10%
  runInBackground: false

permissions:
  exec: []
  http: []
  files: []
  storage:
    maxBytes: 1048576
    secrets: false
  notifications: false

settings: []
```

### 3.3 permissions schema

`exec`는 shell을 거치지 않고 정확한 executable + args pattern만 허용한다.

```yaml
permissions:
  exec:
    - id: aas
      command: aas
      resolve:
        - "$AAS_BIN"
        - "~/.cargo/bin/aas"
        - "/opt/homebrew/bin/aas"
        - "/usr/local/bin/aas"
        - "PATH"
      allowedArgs:
        - ["usage", "--json"]
      timeout: 25s
      maxOutputBytes: 1048576
      sensitiveOutput: false

  http:
    - id: github
      hosts: ["api.github.com"]
      methods: ["GET"]
      timeout: 10s
      cache: true

  files:
    - id: screenshots
      access: read
      prompt: directory
      bookmarkSetting: folder
      defaultPath: "~/Pictures/Screenshots"
      watch: true

  storage:
    maxBytes: 1048576
    secrets: true

  notifications: true
```

권한 변경이 있는 업데이트는 설치 전에 diff를 보여준다.

## 4. Declarative workflow DSL

workflow는 script 없이 host가 실행하는 제한된 DAG다. I/O는 `sources`, 순수 변환은 `transforms`, 렌더링은 `view`로 분리한다.

```yaml
schemaVersion: 1
kind: workflow

sources:
  sourceId:
    use: exec | http | fs.directory | storage
    with: {}

transforms:
  transformId:
    use: map | filter | sort | limit | groupBy | assign
    from: "$.sources.sourceId"
    with: {}

view:
  type: vstack
  children: []

status:
  label: "..."
  tooltip: "..."

schedule:
  nextRefreshAt: "$.computed.nextRefreshAt"
```

표현식은 arbitrary JavaScript가 아니다. v1은 JSONPath + interpolation + 작은 built-in 함수만 제공한다.

지원 built-in:

- `now()`
- `count(list)`
- `date.relative(ms)`
- `date.shortEta(ms)`
- `math.min(list)`
- `coalesce(a, b, ...)`
- `text.truncate(value, length)`
- `file.basename(path)`
- `file.extension(path)`
- `color.healthFromRemaining(percent)`

복잡한 조건문/반복은 `forEach` template로 처리한다. 그 이상이 필요하면 script widget을 사용한다.

## 5. 스크립트 런타임 선택

### 5.1 후보 비교

| 후보 | 장점 | 단점 | 판단 |
|---|---|---|---|
| Embedded JavaScriptCore | macOS 내장, cold start 빠름, Swift `JSContext` bridge 쉬움, TypeScript 사용자가 JS로 접근 가능 | 제3자 코드가 앱 프로세스 안에서 실행됨, CPU 무한 루프 preemption 어려움, 메모리 제한 약함, Node/Deno API 없음, TS transpile 별도 필요 | expression evaluator 정도에는 가능하지만 v1 플러그인 런타임으로는 제외 |
| Embedded Lua | 작고 빠름, sandbox를 만들기 쉬움, 게임/툴 임베딩 사례 많음 | 사용자 저변이 좁음, macOS 기본 런타임 아님, TS/Python 요구와 맞지 않음, 패키지 생태계 약함 | 고성능 local transform용 future runner로는 가능하지만 v1 기본값은 아님 |
| Subprocess Python | process 격리, timeout/kill 쉬움, 사용자가 익숙함, 시스템 자동화에 강함 | macOS에 안정적인 system Python이 없고 venv/패키지 관리 UX가 무거움, 권한 통제는 host API 규율에 의존, cold start 큼 | v1.1 optional runner. 기본 런타임으로는 환경 편차가 큼 |
| Subprocess Deno TypeScript | TS 1급 지원, single binary로 번들 가능, `--allow-*` 권한 모델, npm/node 호환 일부, process 격리, JSON-RPC 구현 쉬움 | 번들 크기 큼, Deno 생태계 학습 필요, app sandbox/MAS와 충돌 가능 | v1 기본 script runner로 추천 |

### 5.2 권장안

v1은 `deno-ts@1`을 기본 script runtime으로 제공한다.

실행 방식:

```text
MenuBucket.app
  -> deno run
       --quiet
       --no-prompt
       --allow-read=<widget bundle dir>
       --allow-env=NO_COLOR,LANG,LC_ALL
       --deny-net
       --deny-run
       --deny-write
       --cached-only
       <bundle>/index.ts
  <-> JSON-RPC over stdin/stdout
```

중요한 점:

- 스크립트는 `Deno.Command`, `fetch`, filesystem write를 직접 쓰지 않는다.
- CLI 실행은 `mb.exec.run()`을 통해 host가 대신 수행한다.
- HTTP는 `mb.http.request()`를 통해 host `URLSession`이 수행한다.
- storage는 host Application Support 또는 Keychain을 통해 수행한다.
- remote imports는 설치/pack 단계에서 lock + vendor 처리한다. 런타임에는 network import를 금지한다.

Mac App Store 샌드박스와 arbitrary CLI execution은 충돌 가능성이 크다. v1 배포는 Developer ID/notarized app을 우선하고, App Store 빌드는 "workflow-only + selected file/http" 제한판으로 따로 고려한다.

## 6. Host <-> Script IPC/API

### 6.1 프로토콜

JSON-RPC 2.0 over stdio를 사용한다. 메시지는 newline-delimited JSON이다.

Host -> script event:

```json
{
  "jsonrpc": "2.0",
  "method": "widget.load",
  "params": {
    "widgetId": "io.menubucket.aas-usage",
    "reason": "open",
    "now": 1783442400000,
    "locale": "ko-KR",
    "appearance": "dark",
    "settings": { "limit": 8 },
    "lastRenderRevision": 12
  }
}
```

Script -> host API call:

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "host.exec.run",
  "params": {
    "command": "aas",
    "args": ["usage", "--json"],
    "parse": "json",
    "timeoutMs": 25000
  }
}
```

Script -> host render:

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "host.render",
  "params": {
    "root": { "type": "text", "text": "Hello" },
    "status": { "label": "OK", "tooltip": "Last updated now" },
    "nextRefreshAt": 1783442430000
  }
}
```

Host -> script action:

```json
{
  "jsonrpc": "2.0",
  "method": "widget.action",
  "params": {
    "actionId": "refresh",
    "payload": {},
    "now": 1783442400000
  }
}
```

### 6.2 Script SDK surface

TypeScript SDK 형태:

```ts
import { mb, ui } from "menubucket";

export default mb.widget({
  async load(ctx) {
    return mb.render(ui.text("ready"));
  },
  async action(ctx, event) {
    if (event.actionId === "refresh") {
      await ctx.reload();
    }
  },
  async timer(ctx, event) {
    await ctx.reload();
  }
});
```

필수 API:

```ts
mb.render(root: UINode, options?: RenderOptions): Promise<void>
```

- `root`: declarative UI tree
- `options.status`: status item label/tooltip/icon
- `options.nextRefreshAt`: 다음 refresh 시각 epoch ms
- `options.cacheTtlMs`: snapshot freshness
- `options.sensitive`: render tree 중 로그 redaction 대상 여부

```ts
mb.timer.once(id: string, atMs: number): Promise<void>
mb.timer.after(id: string, delayMs: number): Promise<void>
mb.timer.every(id: string, intervalMs: number, options?: TimerOptions): Promise<void>
mb.timer.clear(id: string): Promise<void>
```

- 타이머는 host scheduler에 등록된다.
- script process가 죽어도 timer metadata는 host에 남는다.
- `minInterval`은 manifest와 host policy가 강제한다.

```ts
mb.exec.run(options: ExecOptions): Promise<ExecResult>
```

```ts
type ExecOptions = {
  command: string;
  args: string[];
  input?: string | Uint8Array;
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  parse?: "text" | "json" | "lines";
  sensitive?: boolean;
};

type ExecResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
  json?: unknown;
  durationMs: number;
  fromCache?: boolean;
};
```

규칙:

- no shell
- canonical path resolution
- allowed args pattern 검증
- stdout/stderr max bytes 적용
- stderr도 별도 thread/async로 drain
- `sensitive: true`면 로그에 stdout/stderr를 저장하지 않는다.

```ts
mb.http.request(options: HttpOptions): Promise<HttpResult>
```

- host `URLSession` 사용
- manifest `http.hosts` allowlist 적용
- redirect는 같은 host 또는 명시 허용 host만 허용
- 기본은 HTTPS only. `localhost`는 별도 권한으로 허용 가능

```ts
mb.storage.get<T>(key: string): Promise<T | null>
mb.storage.set<T>(key: string, value: T, options?: { ttlMs?: number }): Promise<void>
mb.storage.delete(key: string): Promise<void>
mb.storage.list(prefix?: string): Promise<string[]>
mb.storage.transaction<T>(keys: string[], fn: (values: Record<string, unknown>) => T): Promise<T>
mb.storage.secret.get(key: string): Promise<string | null>
mb.storage.secret.set(key: string, value: string): Promise<void>
```

- 일반 storage는 widget sandbox directory에 JSON/SQLite로 저장한다.
- secret storage는 Keychain에 저장한다.
- quota 초과 시 host가 `StorageQuotaExceeded`를 반환한다.

```ts
mb.notify.show(options: NotifyOptions): Promise<void>
```

- manifest `notifications: true` 필요
- macOS notification 권한은 앱 전체 1회 prompt
- action click은 `widget.action` event로 돌아온다.

UI action built-ins:

- `event`: script로 action event 전달
- `copyText`: host가 pasteboard에 복사
- `openURL`: URL open
- `openFile`: Finder/open
- `revealFile`: Finder reveal

## 7. Declarative UI node schema

### 7.1 공통 필드

```ts
type UINode = {
  id?: string;
  type: string;
  hidden?: boolean;
  accessibility?: {
    label?: string;
    hint?: string;
    value?: string;
  };
  style?: {
    padding?: number | EdgeInsets;
    spacing?: number;
    width?: number | "fill";
    height?: number | "fill";
    minHeight?: number;
    maxHeight?: number;
    alignment?: "leading" | "center" | "trailing";
    background?: SemanticColor;
    foreground?: SemanticColor;
  };
};
```

모든 반복 row/tile에는 안정적인 `id`를 권장한다. renderer는 `id`를 SwiftUI identity와 action routing에 사용한다.

### 7.2 Node types

#### layout

```ts
{ "type": "vstack", "spacing": 8, "children": [/* UINode */] }
{ "type": "hstack", "spacing": 8, "children": [/* UINode */] }
{ "type": "zstack", "children": [/* UINode */] }
{ "type": "scroll", "axis": "vertical", "child": { /* UINode */ } }
{ "type": "divider" }
{ "type": "spacer", "minLength": 8 }
```

SwiftUI mapping:

- `vstack` -> `VStack`
- `hstack` -> `HStack`
- `scroll` -> `ScrollView`
- 작은 popover list는 `VStack`를 기본으로 사용한다. `otpeek`에서 LazyVStack가 self-sizing popover에서 늦게 layout되는 문제가 있었으므로, `virtualized: true`가 명시되거나 row 수가 큰 경우에만 `LazyVStack`로 바꾼다.

#### text

```ts
{
  "type": "text",
  "text": "GitHub",
  "role": "title",
  "lineLimit": 1,
  "truncation": "middle",
  "monospacedDigit": false
}
```

SwiftUI mapping:

- `role: title` -> `.font(.system(size: 13, weight: .semibold))`
- `role: caption` -> `.font(.caption).foregroundStyle(.secondary)`
- `role: code` -> monospaced font
- `monospacedDigit` -> `.monospacedDigit()`

#### image

```ts
{
  "type": "image",
  "source": { "kind": "sfSymbol", "name": "key.fill" },
  "size": 18,
  "tint": "secondary"
}
```

source kinds:

- `sfSymbol`
- `asset`
- `fileIcon`
- `fileThumbnail`
- `url`
- `data`

SwiftUI/AppKit mapping:

- `sfSymbol` -> `Image(systemName:)`
- `fileIcon` -> `NSWorkspace.shared.icon(forFile:)`, `FileIconCache`
- `fileThumbnail` -> `QLThumbnailGenerator`, `ThumbnailCache`, `DiskThumbnailCache`
- 많은 파일 썸네일 grid는 AppKit bridge를 허용한다.

#### list

```ts
{
  "type": "list",
  "items": [
    { "id": "row-1", "type": "hstack", "children": [] }
  ],
  "empty": { "type": "text", "text": "No items" },
  "rowSpacing": 2,
  "virtualized": false
}
```

SwiftUI mapping:

- `ScrollView + VStack` 기본
- `virtualized: true` 또는 item 수가 threshold를 넘으면 `LazyVStack`
- macOS native `List`는 row inset/selection styling이 과하므로 기본 사용하지 않는다.

#### grid

```ts
{
  "type": "grid",
  "columns": { "mode": "adaptive", "minWidth": 72, "maxColumns": 5 },
  "items": [],
  "itemAspectRatio": 0.85
}
```

SwiftUI mapping:

- 일반 data tile -> `LazyVGrid`
- 파일 thumbnail tile -> `NSCollectionView` bridge 가능
- item count와 thumbnail prefetch budget은 host가 관리한다.

#### table

```ts
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
        "usage": { "type": "progress", "value": 0.72 }
      }
    }
  ]
}
```

SwiftUI mapping:

- compact popover table은 `Grid` 또는 `LazyVGrid`로 직접 구성한다.
- header는 sticky로 두지 않는다. popover 안에서는 예측 가능한 높이가 더 중요하다.

#### progress

```ts
{
  "type": "progress",
  "style": "linear",
  "value": 0.72,
  "label": "72%",
  "tint": "warning"
}
```

time-based value:

```ts
{
  "type": "progress",
  "style": "ring",
  "value": {
    "kind": "countdown",
    "from": 1783442400000,
    "until": 1783442430000
  },
  "labelFrom": "remainingSeconds",
  "tintRules": [
    { "whenRemainingLtSeconds": 10, "tint": "danger" }
  ]
}
```

SwiftUI mapping:

- linear -> `ProgressView(value:)` 또는 custom capsule gauge
- ring -> custom `Canvas`/`Shape`
- countdown value는 host `TimelineView(.periodic(..., by: 1))`로 갱신한다. script refresh는 필요 없다.

#### button

```ts
{
  "type": "button",
  "title": "Refresh",
  "icon": { "kind": "sfSymbol", "name": "arrow.clockwise" },
  "role": "normal",
  "action": { "type": "event", "id": "refresh" }
}
```

action variants:

```ts
{ "type": "event", "id": "refresh", "payload": {} }
{ "type": "copyText", "value": "123456", "toast": "Copied" }
{ "type": "openURL", "url": "https://example.com" }
{ "type": "openFile", "path": "/Users/me/file.txt" }
{ "type": "revealFile", "path": "/Users/me/file.txt" }
```

SwiftUI mapping:

- `Button`
- icon은 SF Symbol 우선
- destructive role은 macOS button role에 반영한다.

#### section and badge

```ts
{ "type": "section", "title": "CLAUDE", "children": [] }
{ "type": "badge", "text": "PRO", "tone": "neutral" }
```

SwiftUI mapping:

- `section`은 card가 아니라 unframed group/header로 렌더링한다.
- nested card는 피한다. 반복 item card만 허용한다.

#### empty, banner, switch, none

```ts
{ "type": "empty", "icon": "tray", "title": "No items", "subtitle": "Choose a folder." }
{ "type": "banner", "tone": "warning", "text": "Showing cached data" }
{ "type": "none" }
```

조건부 view 선택:

```ts
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

SwiftUI mapping:

- `empty` -> icon + title/subtitle를 가진 compact placeholder
- `banner` -> semantic tone을 가진 얇은 status row
- `none` -> `EmptyView`
- `switch` -> workflow/render 단계에서 선택된 case만 렌더링

## 8. Refresh / Scheduling model

### 8.1 Trigger 종류

- `install`: 설치 직후 첫 render cache 생성
- `open`: popover가 열림
- `close`: popover가 닫힘
- `interval`: manifest interval
- `timer`: script가 등록한 timer
- `manual`: 사용자가 refresh action 클릭
- `fileEvent`: FSEvents/debounce
- `networkBackoffExpired`: HTTP/CLI backoff 해제
- `wake`: sleep wake 이후 stale widget refresh

### 8.2 Scheduler 정책

기본 흐름:

1. popover open
2. last good render snapshot 즉시 표시
3. snapshot이 stale이면 background refresh 시작
4. refresh 성공 시 UI tree 교체
5. refresh 실패 시 last good render 유지 + error banner 표시

최소 간격:

- host-only countdown/progress: 1초 tick 허용
- script execution foreground min interval: 기본 5초
- script execution background min interval: 기본 60초
- CLI exec timeout: 기본 20초
- HTTP timeout: 기본 15초
- 한 위젯의 동시 refresh는 1개로 coalesce

### 8.3 위젯별 권장 scheduling

OTP:

- account/code refresh는 30초 period boundary마다 수행
- countdown ring/text는 host `TimelineView`로 매초 갱신
- popover가 닫히면 countdown tick 중단

aas usage:

- 자동 polling 기본 비활성
- cache-first 표시
- manual refresh 버튼 제공
- staleAfter는 10-15분 권장
- `aas` 자체 backoff 파일을 존중하되, menubucket도 실패 시 exponential backoff 적용

file recent files:

- FSEvents watch + 250ms debounce
- 팝오버 닫힘 상태에서는 event를 pending으로만 기록
- 팝오버 열림 시 pending reload 처리
- thumbnail prefetch는 visible/near-visible item만 우선

## 9. Error handling

### 9.1 상태 모델

```ts
type WidgetRunState =
  | "notInstalled"
  | "needsPermission"
  | "loading"
  | "ready"
  | "stale"
  | "error"
  | "disabled";
```

host UI 규칙:

- `ready`: 정상 render
- `stale`: last good render + "updated n min ago" 표시
- `error`: last good render 유지, 상단에 compact error row
- `needsPermission`: 권한 요청 CTA 표시
- `disabled`: crash loop 또는 사용자 비활성화

### 9.2 오류 분류

- `ManifestInvalid`
- `PermissionDenied`
- `RuntimeLaunchFailed`
- `ScriptCrash`
- `ScriptTimeout`
- `ScriptProtocolError`
- `ExecNotFound`
- `ExecExitNonZero`
- `ExecOutputTooLarge`
- `HttpDenied`
- `HttpStatus`
- `StorageQuotaExceeded`
- `RenderSchemaInvalid`
- `ActionFailed`

### 9.3 crash loop 정책

- 5분 안에 3회 연속 runtime crash면 widget을 `disabled`로 전환한다.
- 마지막 정상 snapshot은 유지한다.
- 사용자는 "Restart Widget"을 눌러 다시 활성화할 수 있다.
- install/update 직후 발생한 schema 오류는 widget catalog에서 invalid로 표시한다.

### 9.4 로그

로그는 widget별로 저장한다.

```text
~/Library/Logs/MenuBucket/widgets/<widget-id>.log
```

redaction:

- manifest `sensitiveOutput: true` exec 결과
- `storage.secret`
- UI node 중 `sensitive: true`
- known tokens/password patterns

기본 로그 보관:

- widget별 1MB rotate
- 최근 5개 파일 유지

## 10. Sandboxing / security

### 10.1 보안 경계

주요 경계는 앱 프로세스와 script subprocess의 분리다.

- 앱 프로세스: UI, 권한 판단, I/O 수행
- script subprocess: pure transform + host API 요청
- CLI subprocess: host가 직접 spawn하고 timeout/kill

스크립트에 직접 허용하지 않는 것:

- arbitrary network
- arbitrary process spawn
- arbitrary filesystem write
- unbounded stdout/stderr
- shell expansion
- inherited full environment

### 10.2 exec sandbox

`ExecService` 규칙:

- `Process.executableURL`은 canonical path만 사용한다.
- `/bin/sh -c` 금지
- args는 manifest의 allowed pattern과 매칭한다.
- env는 allowlist 기반으로 구성한다.
- cwd는 widget bundle 또는 explicit safe directory만 허용한다.
- timeout 시 process group kill
- stdout/stderr는 byte limit 적용
- stderr drain deadlock 방지

CLI path resolution은 `aas-bar`의 방식을 일반화한다.

```text
1. manifest/env override
2. user configured path
3. common install paths
4. /usr/bin/env <command>
```

### 10.3 HTTP sandbox

- host `URLSession`만 사용
- domain/method allowlist
- HTTPS 기본
- request/response body max bytes
- per-widget rate limit
- cache key는 method + URL + selected headers

### 10.4 file sandbox

- user-selected directory/file은 security-scoped bookmark로 저장한다.
- path string default는 suggestion일 뿐이며, sandboxed build에서는 prompt가 필요하다.
- FSEvents watcher는 bookmark가 유효한 범위에서만 시작한다.
- file thumbnail cache는 path hash로 저장하고 source mtime으로 staleness를 판단한다.

### 10.5 distribution sandbox 현실

arbitrary script/CLI execution 플랫폼은 Mac App Store sandbox와 잘 맞지 않는다. v1은 Developer ID 배포를 기준으로 한다. App Store 변형은 다음 제한판으로 별도 설계한다.

- script runner 비활성 또는 workflow-only
- CLI exec 비활성
- file/http 권한만 허용
- registry도 signed workflow만 허용

## 11. Packaging / distribution

### 11.1 설치 경로

```text
~/Library/Application Support/MenuBucket/Widgets/
  io.menubucket.aas-usage/
    current -> versions/0.1.0
    versions/0.1.0/...
```

cache/log/storage:

```text
~/Library/Caches/MenuBucket/widgets/<id>/
~/Library/Application Support/MenuBucket/widget-storage/<id>/
~/Library/Logs/MenuBucket/widgets/<id>.log
```

### 11.2 배포 형태

1. Single-file widget
   - 장점: 공유 쉬움, gist/문서에 적합
   - 단점: asset/dependency/lock 관리 불리
   - 대상: 작은 workflow, 단순 TS script

2. Directory bundle `.mbwidget`
   - 장점: assets, vendored deps, README, tests 포함 가능
   - 단점: 공유 시 압축 필요
   - 대상: 기본 개발 형태

3. Packed archive `.mbw`
   - zip + manifest hash + optional signature
   - 설치/registry 배포 단위

4. Registry
   - JSON index + signed package
   - host가 permission diff, changelog, hash 검증

### 11.3 registry index 예시

```json
{
  "schemaVersion": 1,
  "widgets": [
    {
      "id": "io.menubucket.aas-usage",
      "name": "aas Usage",
      "version": "0.1.0",
      "api": "1.x",
      "downloadUrl": "https://registry.example/widgets/aas-usage-0.1.0.mbw",
      "sha256": "abc...",
      "signature": "ed25519:...",
      "permissions": {
        "exec": ["aas usage --json"],
        "storage": true
      }
    }
  ]
}
```

### 11.4 개발 도구

향후 CLI:

```bash
menubucket widget init
menubucket widget validate ./MyWidget.mbwidget
menubucket widget run ./MyWidget.mbwidget
menubucket widget pack ./MyWidget.mbwidget -o MyWidget.mbw
menubucket widget inspect-permissions MyWidget.mbw
```

## 12. Grouping / swipe pagination

menubucket popover는 widget을 직접 나열하지 않고 "bucket page"로 구성한다.

```text
Popover
  Header
    group segmented control
    page dots / arrows
  PageViewport
    horizontal swipe pager
      Page 1: Widget A + Widget B
      Page 2: Widget C full
      Page 3: Widget D + Widget E
  Footer
    settings / edit layout / refresh all
```

manifest의 `bucket` 필드:

```yaml
bucket:
  group: Work
  order: 20
  page: auto
  preferredSize:
    width: 360
    minHeight: 140
    maxHeight: 420
```

layout 규칙:

- `page: full` 위젯은 한 페이지를 단독으로 차지한다.
- `page: compact` 위젯은 같은 group의 compact widget과 한 페이지에 묶일 수 있다.
- `page: auto`는 rendered height와 priority를 보고 host가 배치한다.
- trackpad horizontal swipe, keyboard left/right, page dot click을 지원한다.
- popover width는 group 내 최대 preferred width로 맞추되 screen visible frame을 넘지 않는다.

## 13. 예제 위젯 1: OTPeek OTP list

주의: 현재 `otpeek list --json`은 `secret` 필드를 포함한다. 아래 예제는 owned codebase 통합을 위한 fallback이며, production에서는 `otpeek widget --json`처럼 secret 없는 전용 CLI를 추가하는 것을 권장한다.

### 13.1 `menubucket.widget.yaml`

```yaml
schemaVersion: 1
kind: widget

id: io.menubucket.examples.otpeek
name: OTPeek Codes
version: 0.1.0
author:
  name: MenuBucket
description: Shows favorite OTPeek TOTP codes in the menu bucket.

requires:
  host: ">=0.1.0"
  api: "1.x"
  macOS: ">=13.0"

entry:
  kind: script
  runtime: deno-ts@1
  main: index.ts

bucket:
  group: Security
  order: 10
  page: full
  preferredSize:
    width: 340
    minHeight: 180
    maxHeight: 420

statusItem:
  mode: icon
  icon:
    type: sfSymbol
    name: lock.shield.fill
  tooltipFrom: "$.status.tooltip"

refresh:
  onOpen: true
  interval: null
  minInterval: 5s
  staleAfter: 35s
  timeout: 12s
  runInBackground: false

permissions:
  exec:
    - id: otpeek-list
      command: otpeek
      resolve:
        - "$OTPEEK_BIN"
        - "~/.cargo/bin/otpeek"
        - "/opt/homebrew/bin/otpeek"
        - "/usr/local/bin/otpeek"
        - "PATH"
      allowedArgs:
        - ["list", "--json"]
      timeout: 8s
      maxOutputBytes: 1048576
      sensitiveOutput: true
    - id: otpeek-code
      command: otpeek
      resolve:
        - "$OTPEEK_BIN"
        - "~/.cargo/bin/otpeek"
        - "/opt/homebrew/bin/otpeek"
        - "/usr/local/bin/otpeek"
        - "PATH"
      allowedArgs:
        - ["code", "*", "--json"]
      timeout: 8s
      maxOutputBytes: 65536
      sensitiveOutput: true
  storage:
    maxBytes: 262144
    secrets: false
  notifications: false

settings:
  - key: limit
    title: Maximum accounts
    type: integer
    default: 6
    min: 1
    max: 12
  - key: favoritesOnly
    title: Favorites only
    type: boolean
    default: true
```

### 13.2 `index.ts`

```ts
import { mb, ui } from "menubucket";

type OtpAccount = {
  id: string;
  type: "totp" | "hotp";
  issuer?: string;
  accountName: string;
  isFavorite?: boolean;
  sortOrder?: number;
  period?: number;
  color?: string;
};

type OtpCode = {
  code: string;
  validFrom: number;
  validUntil: number;
};

function titleFor(account: OtpAccount): string {
  return account.issuer && account.issuer.length > 0
    ? account.issuer
    : account.accountName;
}

function subtitleFor(account: OtpAccount): string | undefined {
  return account.issuer && account.issuer.length > 0
    ? account.accountName
    : undefined;
}

function formatCode(code: string): string {
  const mid = Math.floor(code.length / 2);
  return `${code.slice(0, mid)} ${code.slice(mid)}`;
}

function remainingSeconds(code: OtpCode, now: number): number {
  return Math.max(0, Math.ceil((code.validUntil - now) / 1000));
}

export default mb.widget({
  async load(ctx) {
    const limit = Number(ctx.settings.limit ?? 6);
    const favoritesOnly = Boolean(ctx.settings.favoritesOnly ?? true);

    const list = await mb.exec.run({
      command: "otpeek",
      args: ["list", "--json"],
      parse: "json",
      sensitive: true,
      timeoutMs: 8000
    });

    let accounts = (list.json as OtpAccount[])
      .filter((account) => account.type === "totp")
      .filter((account) => !favoritesOnly || account.isFavorite)
      .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
      .slice(0, limit);

    const now = Date.now();
    const rows = await Promise.all(accounts.map(async (account) => {
      const result = await mb.exec.run({
        command: "otpeek",
        args: ["code", account.id, "--json"],
        parse: "json",
        sensitive: true,
        timeoutMs: 8000
      });
      return { account, code: result.json as OtpCode };
    }));

    const nextRefreshAt = rows.length > 0
      ? Math.min(...rows.map((row) => row.code.validUntil)) + 250
      : now + 300000;

    await mb.timer.once("totp-boundary", nextRefreshAt);

    const root = ui.vstack({
      spacing: 0,
      children: [
        ui.hstack({
          spacing: 8,
          style: { padding: { horizontal: 10, vertical: 8 } },
          children: [
            ui.image({ source: { kind: "sfSymbol", name: "lock.shield.fill" }, size: 15, tint: "secondary" }),
            ui.text("OTPeek", { role: "title" }),
            ui.spacer(),
            ui.text(`${rows.length} codes`, { role: "caption" })
          ]
        }),
        ui.divider(),
        rows.length === 0
          ? ui.empty({ icon: "key.slash", title: "No TOTP accounts" })
          : ui.list({
              rowSpacing: 2,
              items: rows.map(({ account, code }) => {
                const remaining = remainingSeconds(code, now);
                return ui.hstack({
                  id: account.id,
                  spacing: 10,
                  style: { padding: { horizontal: 10, vertical: 7 } },
                  children: [
                    ui.image({
                      source: { kind: "sfSymbol", name: account.isFavorite ? "star.circle.fill" : "circle.fill" },
                      size: 24,
                      tint: account.isFavorite ? "warning" : "secondary"
                    }),
                    ui.vstack({
                      spacing: 2,
                      style: { width: "fill" },
                      children: [
                        ui.text(titleFor(account), { role: "body", lineLimit: 1 }),
                        subtitleFor(account)
                          ? ui.text(subtitleFor(account)!, { role: "caption", lineLimit: 1, truncation: "middle" })
                          : ui.text("TOTP", { role: "caption" })
                      ]
                    }),
                    ui.progress({
                      style: "ring",
                      value: { kind: "countdown", from: code.validFrom, until: code.validUntil },
                      labelFrom: "remainingSeconds",
                      tintRules: [{ whenRemainingLtSeconds: 10, tint: "danger" }],
                      size: 24
                    }),
                    ui.text(formatCode(code.code), {
                      role: "code",
                      lineLimit: 1,
                      monospacedDigit: true,
                      foreground: remaining < 10 ? "danger" : "primary"
                    }),
                    ui.button({
                      icon: { kind: "sfSymbol", name: "doc.on.doc" },
                      tooltip: "Copy code",
                      action: { type: "copyText", value: code.code, toast: "Copied" }
                    })
                  ]
                });
              })
            })
      ]
    });

    return mb.render(root, {
      nextRefreshAt,
      cacheTtlMs: Math.max(1000, nextRefreshAt - now),
      sensitive: true,
      status: {
        tooltip: rows.length > 0
          ? `OTPeek: ${rows.length} codes`
          : "OTPeek: no accounts"
      }
    });
  },

  async timer(ctx, event) {
    if (event.id === "totp-boundary") {
      await ctx.reload({ reason: "timer" });
    }
  }
});
```

## 14. 예제 위젯 2: aas usage table

### 14.1 `menubucket.widget.yaml`

```yaml
schemaVersion: 1
kind: widget

id: io.menubucket.examples.aas-usage
name: aas Usage
version: 0.1.0
author:
  name: MenuBucket
description: Shows live aas account usage from `aas usage --json`.

requires:
  host: ">=0.1.0"
  api: "1.x"
  macOS: ">=13.0"

entry:
  kind: script
  runtime: deno-ts@1
  main: index.ts

bucket:
  group: Agents
  order: 20
  page: full
  preferredSize:
    width: 360
    minHeight: 180
    maxHeight: 460

statusItem:
  mode: dynamic
  icon:
    type: sfSymbol
    name: gauge.with.dots.needle.bottom.50percent
  labelFrom: "$.status.label"
  tooltipFrom: "$.status.tooltip"

refresh:
  onOpen: true
  interval: null
  minInterval: 30s
  staleAfter: 15m
  timeout: 30s
  runInBackground: false

permissions:
  exec:
    - id: aas-usage
      command: aas
      resolve:
        - "$AAS_BIN"
        - "~/.cargo/bin/aas"
        - "/opt/homebrew/bin/aas"
        - "/usr/local/bin/aas"
        - "PATH"
      allowedArgs:
        - ["usage", "--json"]
      timeout: 25s
      maxOutputBytes: 1048576
      sensitiveOutput: false
  storage:
    maxBytes: 1048576
    secrets: false
  notifications: false

settings:
  - key: maxAgeMinutes
    title: Cache max age
    type: integer
    default: 15
    min: 1
    max: 120
  - key: showOnlyActive
    title: Active accounts only
    type: boolean
    default: false
```

### 14.2 `index.ts`

```ts
import { mb, ui } from "menubucket";

type Meter = {
  label: string;
  usedPct: number;
  resetMs?: number | null;
};

type Account = {
  provider: string;
  name: string;
  email?: string | null;
  active: boolean;
  plan?: string | null;
  planLabel?: string | null;
  headline: string;
  error?: string | null;
  meters: Meter[];
};

type UsageResponse = { accounts: Account[] };
type CachedUsage = { updatedAt: number; data: UsageResponse };

const CACHE_KEY = "usage-cache-v1";

function providerName(id: string): string {
  switch (id) {
    case "claude": return "Claude";
    case "codex": return "Codex";
    case "grok": return "Grok";
    case "zai": return "Z.AI";
    case "cursor": return "Cursor";
    default: return id;
  }
}

function remaining(meter: Meter): number {
  return Math.max(0, Math.min(100, 100 - meter.usedPct));
}

function health(accounts: Account[]): { level: "good" | "warning" | "danger" | "secondary"; label: string } {
  if (accounts.length === 0) return { level: "secondary", label: "no accounts" };
  if (accounts.some((account) => account.error)) return { level: "danger", label: "needs attention" };
  const values = accounts.flatMap((account) => account.meters.map(remaining));
  if (values.length === 0) return { level: "secondary", label: "healthy" };
  const worst = Math.min(...values);
  if (worst < 10) return { level: "danger", label: `worst ${Math.round(worst)}% left` };
  if (worst < 30) return { level: "warning", label: `worst ${Math.round(worst)}% left` };
  return { level: "good", label: `worst ${Math.round(worst)}% left` };
}

function shortEta(ms?: number | null): string {
  if (!ms) return "";
  const diff = ms - Date.now();
  if (diff <= 0) return "now";
  const mins = Math.round(diff / 60000);
  const hours = Math.floor(mins / 60);
  const rem = mins % 60;
  if (hours >= 100) return `${hours}h`;
  if (hours > 0) return rem > 0 ? `${hours}h ${rem}m` : `${hours}h`;
  return `${rem}m`;
}

function groupByProvider(accounts: Account[]): Map<string, Account[]> {
  const grouped = new Map<string, Account[]>();
  for (const account of accounts) {
    if (!grouped.has(account.provider)) grouped.set(account.provider, []);
    grouped.get(account.provider)!.push(account);
  }
  return grouped;
}

async function fetchUsage(): Promise<CachedUsage> {
  const result = await mb.exec.run({
    command: "aas",
    args: ["usage", "--json"],
    parse: "json",
    timeoutMs: 25000
  });
  const cached = { updatedAt: Date.now(), data: result.json as UsageResponse };
  await mb.storage.set(CACHE_KEY, cached);
  return cached;
}

async function loadUsage(force: boolean, maxAgeMinutes: number): Promise<{ cache: CachedUsage | null; error?: string }> {
  const cached = await mb.storage.get<CachedUsage>(CACHE_KEY);
  const stale = !cached || Date.now() - cached.updatedAt > maxAgeMinutes * 60_000;
  if (!force && !stale) return { cache: cached };

  try {
    return { cache: await fetchUsage() };
  } catch (error) {
    if (cached) return { cache: cached, error: error instanceof Error ? error.message : String(error) };
    return { cache: null, error: error instanceof Error ? error.message : String(error) };
  }
}

async function renderUsage(ctx, force = false) {
  const maxAgeMinutes = Number(ctx.settings.maxAgeMinutes ?? 15);
  const activeOnly = Boolean(ctx.settings.showOnlyActive ?? false);
  const { cache, error } = await loadUsage(force, maxAgeMinutes);

  const accounts = (cache?.data.accounts ?? [])
    .filter((account) => !activeOnly || account.active)
    .sort((a, b) => {
      const ae = a.error ? -1 : Math.min(...a.meters.map(remaining), 200);
      const be = b.error ? -1 : Math.min(...b.meters.map(remaining), 200);
      return ae - be;
    });

  const summary = health(accounts);
  const grouped = groupByProvider(accounts);

  const sections = [...grouped.entries()].map(([provider, rows]) => ui.section({
    title: providerName(provider).toUpperCase(),
    icon: { kind: "sfSymbol", name: provider === "zai" ? "z.circle.fill" : "circle.fill" },
    children: rows.map((account) => ui.vstack({
      id: `${account.provider}/${account.name}`,
      spacing: 5,
      style: { padding: { horizontal: 10, vertical: 7 }, background: "secondaryFill" },
      children: [
        ui.hstack({
          spacing: 6,
          children: [
            ui.image({
              source: { kind: "sfSymbol", name: account.active ? "circle.fill" : "circle" },
              size: 7,
              tint: account.active ? "accent" : "secondary"
            }),
            ui.text(account.name, { role: "body", lineLimit: 1, truncation: "middle" }),
            ui.spacer(),
            account.planLabel || account.plan
              ? ui.badge({ text: (account.planLabel ?? account.plan)!.toUpperCase(), tone: "neutral" })
              : ui.text("", { role: "caption" })
          ]
        }),
        account.error
          ? ui.text(account.error, { role: "caption", foreground: "danger", lineLimit: 1 })
          : account.meters.length === 0
            ? ui.text(account.headline, { role: "caption", lineLimit: 1 })
            : ui.vstack({
                spacing: 3,
                children: account.meters.map((meter) => ui.hstack({
                  id: `${account.provider}/${account.name}/${meter.label}`,
                  spacing: 8,
                  children: [
                    ui.text(meter.label, { role: "caption", monospacedDigit: true }),
                    ui.progress({
                      style: "linear",
                      value: Math.max(0, Math.min(1, meter.usedPct / 100)),
                      tint: remaining(meter) < 10 ? "danger" : remaining(meter) < 30 ? "warning" : "good"
                    }),
                    ui.text(`${Math.round(meter.usedPct)}%`, { role: "caption", monospacedDigit: true }),
                    ui.text(shortEta(meter.resetMs), { role: "caption", monospacedDigit: true, foreground: "tertiary" })
                  ]
                }))
              })
      ]
    }))
  }));

  const root = ui.vstack({
    spacing: 0,
    children: [
      ui.hstack({
        spacing: 6,
        style: { padding: { horizontal: 12, vertical: 9 } },
        children: [
          ui.text("aas", { role: "title" }),
          ui.image({ source: { kind: "sfSymbol", name: "circle.fill" }, size: 7, tint: summary.level }),
          ui.text(summary.label, { role: "caption" }),
          ui.spacer(),
          cache
            ? ui.text(mb.date.relative(cache.updatedAt), { role: "caption", foreground: "tertiary" })
            : ui.text("not loaded", { role: "caption", foreground: "tertiary" })
        ]
      }),
      error ? ui.banner({ tone: "warning", text: `Showing cached data: ${error}` }) : ui.none(),
      ui.divider(),
      accounts.length === 0
        ? ui.empty({ icon: "person.crop.circle.badge.exclamationmark", title: "No accounts", subtitle: error ?? "Run aas login to add one" })
        : ui.scroll({ child: ui.vstack({ spacing: 11, style: { padding: 12 }, children: sections }) }),
      ui.divider(),
      ui.hstack({
        spacing: 8,
        style: { padding: { horizontal: 12, vertical: 8 } },
        children: [
          ui.button({
            title: "Refresh",
            icon: { kind: "sfSymbol", name: "arrow.clockwise" },
            action: { type: "event", id: "refresh" }
          }),
          ui.spacer(),
          ui.button({
            icon: { kind: "sfSymbol", name: "terminal" },
            tooltip: "Open aas documentation",
            action: { type: "openURL", url: "https://github.com/Open330/aas" }
          })
        ]
      })
    ]
  });

  return mb.render(root, {
    cacheTtlMs: maxAgeMinutes * 60_000,
    status: {
      label: summary.level === "danger" ? "!" : "",
      tooltip: `aas: ${summary.label}`
    }
  });
}

export default mb.widget({
  async load(ctx) {
    return renderUsage(ctx, false);
  },
  async action(ctx, event) {
    if (event.actionId === "refresh") {
      return renderUsage(ctx, true);
    }
  }
});
```

## 15. 예제 위젯 3: file-stack recent files

이 예제는 script가 아니라 workflow다. `file-stack`의 핵심 자산인 directory listing, FSEvents, icon/thumbnail cache를 menubucket host service로 일반화한다.

### 15.1 `menubucket.widget.yaml`

```yaml
schemaVersion: 1
kind: widget

id: io.menubucket.examples.recent-files
name: Recent Files
version: 0.1.0
author:
  name: MenuBucket
description: Shows recent files from a selected folder using native thumbnails.

requires:
  host: ">=0.1.0"
  api: "1.x"
  macOS: ">=13.0"

entry:
  kind: workflow
  runtime: workflow@1
  main: workflow.yaml

bucket:
  group: Files
  order: 30
  page: full
  preferredSize:
    width: 360
    minHeight: 220
    maxHeight: 460

statusItem:
  mode: icon
  icon:
    type: sfSymbol
    name: folder.fill
  tooltipFrom: "$.status.tooltip"

refresh:
  onOpen: true
  interval: null
  minInterval: 2s
  staleAfter: 10m
  timeout: 10s
  runInBackground: false

permissions:
  files:
    - id: recent-folder
      access: read
      prompt: directory
      bookmarkSetting: folder
      defaultPath: "~/Pictures/Screenshots"
      watch: true
  storage:
    maxBytes: 262144
    secrets: false
  notifications: false

settings:
  - key: folder
    title: Folder
    type: directory
    default: "~/Pictures/Screenshots"
    permission: recent-folder
  - key: limit
    title: Maximum files
    type: integer
    default: 24
    min: 6
    max: 80
  - key: viewMode
    title: View mode
    type: enum
    default: grid
    options:
      - grid
      - list
```

### 15.2 `workflow.yaml`

```yaml
schemaVersion: 1
kind: workflow

sources:
  files:
    use: fs.directory
    with:
      permission: recent-folder
      path: "${settings.folder}"
      watch: true
      skipHidden: true
      resourceKeys:
        - localizedName
        - contentModificationDate
        - typeIdentifier
        - fileSize
        - isDirectory
        - tagNames
      sort:
        by: contentModificationDate
        direction: descending
      limit: "${settings.limit}"

transforms:
  visibleFiles:
    use: assign
    from: "$.sources.files.items"

view:
  type: vstack
  spacing: 0
  children:
    - type: hstack
      spacing: 8
      style:
        padding:
          horizontal: 12
          vertical: 9
      children:
        - type: image
          source:
            kind: sfSymbol
            name: folder.fill
          size: 15
          tint: secondary
        - type: text
          text: "${file.basename(settings.folder)}"
          role: title
          lineLimit: 1
        - type: spacer
        - type: text
          text: "${count(transforms.visibleFiles)} items"
          role: caption
    - type: text
      text: "${settings.folder}"
      role: caption
      lineLimit: 1
      truncation: middle
      style:
        padding:
          horizontal: 12
          bottom: 8
    - type: divider
    - type: switch
      value: "${settings.viewMode}"
      cases:
        grid:
          type: grid
          columns:
            mode: adaptive
            minWidth: 76
            maxColumns: 4
          itemAspectRatio: 0.92
          style:
            padding: 12
          items:
            forEach: "$.transforms.visibleFiles"
            as: file
            template:
              type: button
              id: "file-${file.id}"
              action:
                type: openFile
                path: "${file.path}"
              child:
                type: vstack
                spacing: 5
                children:
                  - type: image
                    source:
                      kind: fileThumbnail
                      path: "${file.path}"
                      modifiedAt: "${file.contentModificationDate}"
                    size:
                      width: 72
                      height: 54
                    fallback:
                      kind: fileIcon
                      path: "${file.path}"
                  - type: text
                    text: "${file.localizedName}"
                    role: caption
                    lineLimit: 2
                    truncation: middle
                  - type: text
                    text: "${date.relative(file.contentModificationDate)}"
                    role: caption2
                    foreground: tertiary
        list:
          type: list
          rowSpacing: 1
          items:
            forEach: "$.transforms.visibleFiles"
            as: file
            template:
              type: hstack
              id: "file-${file.id}"
              spacing: 8
              style:
                padding:
                  horizontal: 10
                  vertical: 6
              children:
                - type: image
                  source:
                    kind: fileIcon
                    path: "${file.path}"
                  size: 22
                - type: vstack
                  spacing: 2
                  style:
                    width: fill
                  children:
                    - type: text
                      text: "${file.localizedName}"
                      role: body
                      lineLimit: 1
                      truncation: middle
                    - type: text
                      text: "${file.path}"
                      role: caption
                      lineLimit: 1
                      truncation: middle
                - type: text
                  text: "${date.relative(file.contentModificationDate)}"
                  role: caption
                  foreground: secondary
                - type: button
                  icon:
                    kind: sfSymbol
                    name: magnifyingglass
                  tooltip: Reveal in Finder
                  action:
                    type: revealFile
                    path: "${file.path}"

empty:
  type: empty
  icon: tray
  title: No files
  subtitle: Choose another folder in widget settings.

status:
  tooltip: "Recent files: ${count(transforms.visibleFiles)} items"
```

## 16. 구현 순서 제안

### M1 - Native host skeleton

- Swift Package 또는 Xcode project 생성
- `NSStatusItem + NSPopover + NSHostingController`
- popover open/close lifecycle
- right-click settings/quit menu
- static sample `UINode` 렌더링

### M2 - UINode renderer

- Codable `UINode` enum
- `text`, `vstack`, `hstack`, `list`, `grid`, `progress`, `button`, `image`
- action router
- last good render cache

### M3 - RuntimeSupervisor + Deno JSON-RPC

- subprocess launch/kill/restart
- JSON-RPC framing
- `render`, `timer`, `storage`
- fixture widget tests

### M4 - Exec/HTTP/File services

- manifest permission parser
- `exec.run` with path resolution/timeout/output limit
- `http.request`
- `fs.directory` + FSEvents + security-scoped bookmarks

### M5 - Scheduler and grouping

- open/manual/timer/fileEvent triggers
- stale-while-revalidate
- group/page model
- horizontal swipe pager

### M6 - Packaging and validation

- `.mbwidget` loader
- `.mbw` pack/unpack
- schema validation
- permission diff UI
- local registry index prototype

## 17. Open questions

1. v1 배포 채널을 Developer ID로 고정할지, App Store 제한판을 동시에 고려할지 결정해야 한다.
2. `otpeek`에는 secret 없는 menubucket 전용 JSON command를 추가하는 것이 안전하다.
3. Python/Lua runner를 v1에 포함할지, API protocol만 고정하고 v1.1로 미룰지 결정해야 한다.
4. widget registry를 처음부터 운영할지, local/GitHub install만 먼저 지원할지 결정해야 한다.
5. workflow expression language를 JSONPath 수준으로 제한할지, CEL 같은 검증된 표현식 엔진을 도입할지 검토가 필요하다.

## 18. 최종 권장 범위

v1 MVP는 다음으로 자른다.

- AppKit status item host
- SwiftUI native renderer
- directory bundle install
- workflow runner
- Deno TypeScript runner
- exec/http/storage/file/notify permission model
- grouping + swipe pagination
- 예제 위젯 3개: OTPeek, aas, Recent Files

미룰 것:

- Python/Lua production runner
- public registry
- App Store sandbox build
- remote dependency install at runtime
- arbitrary plugin background daemon
