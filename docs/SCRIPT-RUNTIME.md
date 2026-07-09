# BarShelf 스크립트 런타임

이 문서는 M2 `script` 위젯 런타임의 공통 계약과 TypeScript SDK 사용법을 설명한다. 런타임 v1은 Deno TypeScript 프로세스와 호스트가 newline-delimited JSON-RPC 2.0으로 통신한다.

관련 문서:

- 시작하기: [`docs/GETTING-STARTED.md`](GETTING-STARTED.md)
- URL 설치: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 위젯 배포: [`docs/PUBLISHING.md`](PUBLISHING.md)
- Manifest/UINode 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)

## JSON-RPC 프로토콜 v1

전송: **newline-delimited JSON-RPC 2.0 over stdio**. 한 줄이 한 메시지이며 stdout에는 JSON-RPC 메시지만 쓴다. stderr는 위젯 로그로 스트리밍된다.

### 호스트 -> 스크립트 알림

| method | params |
|---|---|
| `widget.load` | `{widgetId, reason: "install"\|"open"\|"manual"\|"timer"\|"interval", now, locale, appearance: "light"\|"dark", settings, lastRenderRevision}` |
| `widget.action` | `{actionId, payload, now}` |
| `widget.timer` | `{id, now}` |

### 스크립트 -> 호스트 요청

Script -> Host 방향은 `id`가 필수이며, 호스트는 `result` 또는 `error`로 응답한다.

| method | params -> result |
|---|---|
| `host.render` | `{root: UINode, status?: {label?, tooltip?}, nextRefreshAt?, cacheTtlMs?, sensitive?}` -> `{revision}` |
| `host.exec.run` | `{command, args, parse?: "text"\|"json"\|"lines", timeoutMs?, sensitive?, env?}` -> `{exitCode, stdout, stderr, json?, durationMs}`. manifest `permissions.exec` allowlist가 강제된다. |
| `host.storage.get/set/delete/list` | `{key, value?, prefix?}` -> 값 또는 키 목록. 위젯별 네임스페이스를 사용하며 quota는 1MB이다. |
| `host.secret.get/set` | `{key, value?}`. Keychain service는 `dev.barshelf`, account는 `<widgetId>/<key>`이다. manifest `permissions.keychain: true`가 필요하다. |
| `host.timer.once/after/every/clear` | `{id, atMs?/delayMs?/intervalMs?}`. 호스트 Scheduler에 등록되며 `minInterval`은 호스트가 강제한다. |
| `host.notify.show` | `{title, body?}`. manifest `permissions.notifications: true`가 필요하다. |
| `host.log` | `{level: "debug"\|"info"\|"warn"\|"error", message}` -> 위젯 로그 파일. |

오류 코드:

| code | name |
|---:|---|
| `-32001` | `PermissionDenied` |
| `-32002` | `ExecNotFound` |
| `-32003` | `Timeout` |
| `-32004` | `QuotaExceeded` |
| `-32005` | `ProtocolError` |

### Deno 실행

호스트가 조립하는 실행 커맨드:

```bash
deno run --quiet --no-prompt --no-remote \
  --allow-read=<widget-bundle-dir> \
  --import-map=<generated-import-map.json> \
  <bundle>/index.ts
```

생성 import map은 다음 형태이다.

```json
{ "imports": { "barshelf": "file://<sdk>/mod.ts" } }
```

Deno 탐색 순서:

1. `$DENO_BIN`
2. `/opt/homebrew/bin/deno`
3. `/usr/local/bin/deno`
4. `~/.deno/bin/deno`
5. `PATH`

SDK 위치는 개발 모드에서 `./sdk/mod.ts`이고, 번들 모드에서는 앱 리소스 안의 SDK를 가리킨다.

샌드박스 플래그의 의미:

- `--quiet`: 런타임 noise를 줄여 stdout JSON-RPC framing을 보호한다.
- `--no-prompt`: 권한 prompt로 프로세스가 멈추는 것을 금지한다.
- `--no-remote`: 런타임 중 remote import를 금지한다.
- `--allow-read=<widget-bundle-dir>`: 위젯 번들 내부 파일 읽기만 허용한다.
- `--import-map=...`: `import { barshelf, ui } from "barshelf"`을 로컬 SDK 파일로 고정한다.

스크립트는 직접 `Deno.Command`, network, 파일 쓰기를 사용하지 않는다. exec, storage, secret, timer, notification은 모두 `barshelf.*` API를 통해 호스트에 요청한다.

## SDK API

위젯은 SDK를 import하고 `barshelf.widget({ load, action, timer })`를 한 번 등록한다.
짧은 별칭이 필요하면 `bsf`를 같은 객체로 import할 수 있다.

```ts
import { barshelf, ui } from "barshelf";

export default barshelf.widget({
  async load(ctx) {
    await barshelf.render(ui.text(`Loaded at ${ctx.now}`));
  },

  async action(ctx) {
    if (ctx.actionId === "refresh") {
      await ctx.reload();
    }
  },

  async timer(ctx) {
    await barshelf.log("debug", `timer fired: ${ctx.id}`);
  },
});
```

### 생명주기

```ts
barshelf.widget({
  load?: (ctx) => void | Promise<void>,
  action?: (ctx, event) => void | Promise<void>,
  timer?: (ctx, event) => void | Promise<void>,
})
```

- `load(ctx)`: `widget.load` notification 처리. `ctx`에는 `widgetId`, `reason`, `now`, `locale`, `appearance`, `settings`, `lastRenderRevision`이 있다.
- `action(ctx, event)`: `event` action 처리. `ctx.actionId`와 `ctx.payload`를 사용한다.
- `timer(ctx, event)`: host timer 처리. `ctx.id`와 `ctx.now`를 사용한다.
- 모든 context에는 `render`, `exec`, `storage`, `secret`, `timer`, `notify`, `log`, `ui`, `barshelf`, `bsf`, `reload()`가 포함된다.

### 렌더

```ts
await barshelf.render(root, {
  status: { label: "12:34", tooltip: "Updated now" },
  nextRefreshAt: Date.now() + 60_000,
  cacheTtlMs: 60_000,
  sensitive: false,
});
```

`root`는 `schema/uinode-0.1.json`과 일치하는 UINode이다. `barshelf.render`는 `host.render` 요청을 보내고 `{revision}`을 반환한다.

### 실행

```ts
const result = await barshelf.exec.run({
  command: "aas",
  args: ["usage", "--json"],
  parse: "json",
  timeoutMs: 25_000,
});
```

호스트는 manifest `permissions.exec` allowlist, timeout, output limit, sensitive 정책을 강제한다.

### 저장소

```ts
const count = await barshelf.storage.get<number>("count") ?? 0;
await barshelf.storage.set("count", count + 1);
await barshelf.storage.delete("count");
const keys = await barshelf.storage.list("prefix:");
```

일반 storage는 위젯별 네임스페이스와 1MB quota를 가진다.

### 시크릿

```ts
const token = await barshelf.secret.get("token");
await barshelf.secret.set("token", "value");
```

Keychain 접근은 manifest `permissions.keychain: true`가 필요하다. 계정명은 `<widgetId>/<key>`이다.

### 타이머

```ts
await barshelf.timer.once("deadline", Date.now() + 30_000);
await barshelf.timer.after("retry", 5_000);
await barshelf.timer.every("minute", 60_000);
await barshelf.timer.clear("minute");
```

Timer metadata는 호스트 Scheduler가 보관한다. 스크립트 프로세스가 재시작되어도 같은 id로 다시 등록할 수 있으며, 최소 간격은 호스트가 적용한다.

### 알림과 로그

```ts
await barshelf.notify.show({ title: "Done", body: "Widget finished work." });
await barshelf.log("info", "render complete");
```

Notification은 manifest `permissions.notifications: true`가 필요하다.

## UI 헬퍼

`ui.*` helper는 `schema/uinode-0.1.json`과 일치하는 JSON 객체를 만든다. 원자
노드 helper와, 제품형 카드 UI를 빠르게 만들기 위한 조합 helper를 함께 제공한다.

```ts
const root = ui.vstack([
  ui.header("Script Clock", { icon: "clock", badge: "TS" }),
  ui.metricCard("Minute", "50%", {
    icon: "clock.fill",
    tone: "accent",
    progress: 0.5,
  }),
  ui.button("Increment", ui.action.event("increment"), {
    icon: "plus.circle",
  }),
], { spacing: 8 });
```

제공 helper:

- `ui.vstack(children, options)`, `ui.hstack(children, options)`
- `ui.list(items, options)`, `ui.section(title, children, options)`
- `ui.text(text, options)`, `ui.image(source, options)`
- `ui.progress(valueOrOptions, options)`
- `ui.button(title, action, options)`
- `ui.badge(text, options)`, `ui.banner(text, options)`
- `ui.empty(options)`, `ui.divider(options)`, `ui.spacer(minLength, options)`
- `ui.header(title, options)`, `ui.metricCard(title, value, options)`
- `ui.meterRow(label, value, options)`, `ui.stat(label, value, options)`

Action helper:

- `ui.action.event(id, payload?)`
- `ui.action.copyText(value, options?)`
- `ui.action.openURL(url)`
- `ui.action.openFile(path)`
- `ui.action.revealFile(path)`
- `ui.action.run(command, options?)`
- `ui.action.refresh()`

## clock-script 워크스루

예제 위치:

- `widgets/clock-script/widget.json`
- `widgets/clock-script/index.ts`

Manifest 핵심:

```json
{
  "entry": { "kind": "script", "runtime": "deno-ts@1" },
  "source": { "kind": "script", "output": "viewtree" },
  "bucket": { "group": "Demo", "order": 30, "size": "S" },
  "permissions": {
    "storage": true,
    "exec": [],
    "network": [],
    "readPaths": [],
    "env": [],
    "keychain": false,
    "notifications": false
  }
}
```

동작:

1. 호스트가 Deno 프로세스를 시작하고 `widget.load` notification을 보낸다.
2. `load` handler는 `barshelf.timer.every("clock-minute", 60_000)`로 1분 timer를 등록한다.
3. 현재 시각과 storage의 클릭 수를 읽어 `barshelf.render`로 UINode를 보낸다.
4. 버튼은 `{type: "event", id: "increment"}` action을 사용한다.
5. 호스트가 버튼 클릭을 `widget.action`으로 전달하면 스크립트가 storage count를 증가시키고 다시 render한다.
6. 1분 timer가 `widget.timer`로 도착하면 현재 시각을 다시 render한다.

## 생명주기와 크래시 정책

- 위젯당 상주 프로세스는 1개이다.
- refresh 트리거 시 프로세스가 살아 있으면 `widget.load` notification을 재전송한다.
- 프로세스가 죽어 있으면 호스트가 재기동한다.
- stdout 라인은 1MB로 제한된다.
- 응답 없는 요청 timeout은 20초이다.
- stderr는 위젯 로그로 스트리밍된다.
- 5분 안에 3회 crash가 발생하면 위젯은 `disabled` 상태가 되고 마지막 snapshot을 유지한다.
- disabled 상태에서는 "Restart Widget" 액션으로 사용자가 명시적으로 재시작한다.
