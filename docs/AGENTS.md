# BarShelf Widget Authoring Spec (for agents)

Everything an LLM agent needs to author a BarShelf widget end-to-end. This file
is the ground truth for the manifest, the three execution layers, the UINode
view tree, settings, appearance, permissions, triggers, and the build/test loop.
It matches the shipping code (schema v0.1). Terse by design — read once, build.

BarShelf is a macOS menu-bar app. A **widget** is a directory containing a
`widget.json` manifest plus its entry file(s). At refresh time the host produces
a **UINode** view tree (a JSON UI description) and renders it natively in the
popup. A widget never draws pixels; it emits UINode JSON.

---

## 1. Package layout

```
my-widget/
  widget.json        # manifest (required)
  <entry file>       # depends on entry.kind (see §3)
```

Entry file by kind:
- `exec`     → an executable script/binary you run (e.g. `widget.sh`); `source.command` points at it.
- `workflow` → `workflow.json` (declarative, no code).
- `script`   → `index.ts` (Deno TypeScript using the `barshelf` SDK).

The widget `id` becomes its install directory name, so keep it filesystem-safe:
letters/digits plus `-` `_` `.`, must start with a letter or digit, no `..`,
≤100 chars.

---

## 2. Decision rule — exec vs workflow vs script

Pick the **least powerful** layer that does the job:

| Use… | When | Runs |
|---|---|---|
| **workflow** | Data comes from a local command, a directory listing, or an HTTPS JSON GET, and the view is a straightforward mapping of that data. **Prefer this.** No code, declarative, safest. | Host-executed sources → pure transforms → templated view. |
| **exec** | You need a shell/binary to compute the whole view and can emit UINode JSON (or feed a builtin data adapter). | Your command runs each refresh; stdout is the view (or adapter input). |
| **script** | You need persistent state, timers/countdowns, click handlers that mutate state, secrets, or notifications — i.e. interactivity/logic a template can't express. | A long-lived Deno process talking JSON-RPC to the host via the `barshelf` SDK. |

Rule of thumb: **workflow first**; drop to **exec** only if the shell already
produces what you want; use **script** only when you need live logic/state.

---

## 3. Manifest (`widget.json`)

Unknown top-level keys are tolerated (ignored by the decoder), so `$schema` and
`version` are safe to include and recommended. Every field below is optional
except `schemaVersion`, `id`, `name`, and `entry`.

```jsonc
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",  // optional, tolerated
  "schemaVersion": 1,                 // REQUIRED (int)
  "id": "dev.you.my-widget",          // REQUIRED, filesystem-safe (see §1)
  "name": "My Widget",                // REQUIRED, display name
  "version": "0.1.0",                 // recommended string; used for display/updates
  "icon": "sparkles",                 // SF Symbol name

  "bucket": {                         // where it sits in the shelf
    "group": "My Widgets",            // section title
    "order": 0,                       // sort within group
    "size": "S"                       // "XS" | "S" | "M" | "L"  (XS = menu-bar)
  },

  "entry": {                          // REQUIRED
    "kind": "exec",                   // "exec" | "workflow" | "script" | "builtin"
    "runtime": "deno-ts@1",           // script only; only "deno-ts@1" is supported
    "main": "workflow.json"           // entry file; default: script→index.ts, workflow→workflow.json
  },

  "source": {                         // exec/script data source (see §4/§6)
    "kind": "exec",                   // "exec" | "script"
    "command": ["./widget.sh"],       // exec: argv
    "discover": ["$MYTOOL", "~/bin/tool", "PATH"], // optional binary discovery
    "timeoutMs": 5000,
    "output": "viewtree",             // "viewtree" (emit UINode) | "data" (feed adapter)
    "adapter": "aas.usage"            // only when output="data"; builtin adapter name
  },

  "refresh": {                        // see §8
    "onOpen": true,
    "interval": 60,                   // seconds; omit/null = no interval polling
    "staleAfterSec": 30,
    "watchPaths": ["~/Downloads"],    // FSEvents paths, 250ms debounce, ~ expands
    "runInBackground": false,
    "triggers": ["wake", "popup-open", { "fs": "~/Downloads" }, "url"]  // R12, see §8
  },

  "statusItem": {                     // menu-bar (XS) promotion; only "none" is active today
    "mode": "none"                    // "none" | "icon" | "text" | "dynamic"
  },

  "permissions": { /* see §9 */ },
  "settings": [ /* see §5 */ ],
  "appearance": { /* see §7 */ }
}
```

Notes:
- `refresh.interval` **null / omitted = no polling** (cache-first). Set a number of
  seconds to poll.
- `source.output: "data"` routes stdout through a builtin adapter (`source.adapter`).
  Only a small set of builtin adapters exists; for anything custom use
  `output: "viewtree"` and emit UINode JSON yourself.
- **`category` and `screenshot` are NOT manifest fields.** They live on the
  *registry* entry (see §11). Do not put them in `widget.json`.

---

## 4. exec layer

`entry.kind = "exec"`, `source.kind = "exec"`. The host runs `source.command`
(argv; first element resolved against `source.discover` if given), captures
stdout, and:

- `output: "viewtree"` → stdout **is** a UINode JSON object (see §12A).
- `output: "data"` → stdout is fed to the builtin `source.adapter`.

Exec that runs any command requires a matching `permissions.exec` allowlist
entry (§9). `timeoutMs` bounds runtime.

---

## 5. `settings[]` — user-configurable inputs

Each entry describes one setting; the host generates the UI and passes values to
workflows (as `${settings.<key>}`) and scripts. Fields (all optional, decode-only
shape):

```jsonc
{
  "key": "folder",         // identifier used in ${settings.folder}
  "type": "directory",     // e.g. "string" | "integer" | "number" | "boolean" | "enum" | "directory"
  "title": "Folder",       // label shown in settings UI (label also accepted)
  "options": ["a", "b"],   // for enum types
  "min": 1, "max": 48,     // numeric bounds
  "default": "~/Downloads" // default value (any JSON type)
}
```

The host also shows a built-in **Appearance** section for every widget (accent,
density, card style, show-header) on top of your `settings[]`.

---

## 6. script layer (Deno + `barshelf` SDK)

`entry.kind = "script"`, `entry.runtime = "deno-ts@1"`, `source.kind = "script"`,
`source.output = "viewtree"`, entry file `index.ts`. The script is a long-lived
Deno process (run with `--no-remote --no-prompt`, read-only access to its own
dir) that talks JSON-RPC to the host via the SDK. Import with:

```ts
import { mb, ui, action, type WidgetLoadContext, type WidgetActionContext, type WidgetTimerContext } from "barshelf";
```

Register handlers and start the loop:

```ts
export default mb.widget({
  load,     // (ctx: WidgetLoadContext)   — first run / open / manual / timer / interval
  action,   // (ctx, event)               — a UINode action of type "event" fired
  timer,    // (ctx, event)               — a scheduled timer fired
});
```

Host APIs (all `async`, reachable via `mb.*` or the context object):

- `mb.render(root: UINode, opts?)` — push a view tree. `opts`: `{ status?, nextRefreshAt?, cacheTtlMs?, sensitive? }`.
- `mb.exec.run({ command, args?, parse?, timeoutMs?, sensitive?, env? })` — run an allowlisted command; `parse`: `"text" | "json" | "lines"`. Needs `permissions.exec`.
- `mb.storage.get/set/delete/list(prefix?)` — per-widget KV store, ~1 MB quota. **No permission needed.**
- `mb.secret.get/set(key[, value])` — Keychain-backed; account `<widgetId>/<key>`. Needs `permissions.keychain`.
- `mb.timer.once(id, atMs) / after(id, delayMs) / every(id, intervalMs) / clear(id)` — schedule callbacks into your `timer` handler.
- `mb.notify.show({ title, body? })` — system notification. Needs `permissions.notifications`.
- `mb.log(level, message)` — `"debug" | "info" | "warn" | "error"`.
- `ui.*` / `action.*` — typed builders that return UINode / NodeAction objects (see §10).

The script never touches the network or filesystem directly — everything goes
through `mb.*`, which the host gates by manifest permissions.

---

## 7. `appearance` — theming (R12)

Author defaults; the user can override each field in settings. All fields
optional; omitted = inherit. Lenient decode (a bad value becomes `nil`, never a
parse failure). Neutral (all absent) renders exactly as an un-themed widget.

```jsonc
"appearance": {
  "accent": "blue",       // SF color name: default|blue|purple|pink|red|orange|yellow|green|gray  OR  "#RRGGBB"
  "density": "regular",   // "compact" | "regular"   (compact tightens padding/fonts ~0.85x)
  "cardStyle": "plain",   // "plain" | "tinted"      (tinted = accent-wash card background)
  "showHeader": true      // false hides the card header row (refresh stays in the context menu)
}
```

Effective appearance = user override merged over author default merged over
neutral (field-wise, user wins). `accent` recolors progress/meter/badge/link;
`density` scales padding/text.

---

## 8. `refresh` and triggers

- `onOpen` — refresh when the popup opens.
- `interval` — seconds between polls; omit/null = no polling.
- `staleAfterSec` — cached view considered stale after N seconds.
- `watchPaths` — FSEvents-watched paths (250 ms debounce, `~` expands).
- `runInBackground` — allow relaxed polling while the popup is closed.
- `triggers` (R12) — event-driven refreshes. Array of mixed strings/objects;
  unrecognized entries are silently dropped:
  - `"wake"` — on system wake (`NSWorkspace.didWakeNotification`).
  - `"popup-open"` (aliases `"popupOpen"`, `"open"`) — every popup open, debounced ≥5 s/widget.
  - `{ "fs": "~/path" }` — a directory/file change (FSEvents, ~2 s coalesce, `~` expands).
  - `"url"` — refreshed via the deep link `barshelf://refresh?widget=<id>` (see §10 test loop).

Triggered refreshes respect scheduler coalescing (they won't double-fire with
interval polling).

---

## 9. Permission model

Declared in `permissions`; approval is **per-widget and all-at-once**: the host
hashes the whole declared set and asks the user to approve on first run.
**Deny-by-default** — nothing gated runs until approved. Changing the declared
permissions invalidates approval (re-approval required).

```jsonc
"permissions": {
  "exec": [                          // allowlist of runnable commands
    {
      "command": "/bin/ls",          // exact command
      "allowedArgs": [["-la", "*"]], // argv patterns (excl. command); "*" = exactly one arg
      "env": ["HOME"],               // env vars this command may receive
      "maxOutputBytes": 65536,
      "sensitiveOutput": false       // true → output treated as sensitive (redacted/cleared)
    }
  ],
  "network": ["api.github.com"],     // hosts the widget may HTTPS-GET (enables workflow "http" source)
  "readPaths": ["~/Downloads"],      // paths the widget may read (e.g. fs.directory source)
  "env": ["HOME", "PATH"],           // env vars exposed to processes
  "keychain": true,                  // allow mb.secret.* (Keychain)
  "notifications": true              // allow mb.notify.show
}
```

Gating specifics:
- Any exec (workflow `exec` source, UINode `run` action, `mb.exec.run`) must
  match an `exec` allowlist entry.
- The workflow **`http` source requires a non-empty `network` list** (the R12
  `network` permission). https only; GET only; 20 s timeout; 5 MB cap; no
  redirect downgrade to non-https.
- `keychain` gates `mb.secret.*`; `notifications` gates `mb.notify.show`.
- `mb.storage.*` needs **no** permission (per-widget sandbox).

The install-confirm summary (`mbk install`) prints one line per gated capability,
e.g. `exec: /bin/ls`, `network: fetches from api.github.com`, `keychain: …`,
`notifications: …`. The gallery shows the same as chips.

---

## 10. UINode catalog

The view tree is one root UINode object. `type` is a string discriminator; every
other field is optional; unknown types decode fine but render as a placeholder.
**The native renderer knows exactly these 13 types** (anything else, including the
SDK's `zstack`/`scroll`/`none`, renders as an unsupported placeholder today):

`vstack`, `hstack`, `list`, `section`, `text`, `image`, `progress`, `button`,
`badge`, `banner`, `empty`, `divider`, `spacer`.

Shared/common fields: `id` (stable identity, needed for lists & action routing),
`padding` (points), `widthFill` (bool), `tint`/`tone`/`foreground`
(`primary`|`secondary`|`tertiary`|`accent`|`good`|`warning`|`danger`|`neutral`),
`accessibilityLabel`.

### Containers

```json
{ "type": "vstack", "spacing": 8, "children": [ { "type": "text", "text": "A" } ] }
```
```json
{ "type": "hstack", "spacing": 8, "children": [
  { "type": "text", "text": "Left" },
  { "type": "spacer" },
  { "type": "text", "text": "Right", "role": "caption" }
] }
```
```json
{ "type": "list", "spacing": 2, "items": [
  { "type": "hstack", "id": "row-1", "children": [ { "type": "text", "text": "Row 1" } ] }
] }
```
```json
{ "type": "section", "title": "Recent", "spacing": 4, "children": [
  { "type": "text", "text": "item" }
] }
```

### Text

```json
{ "type": "text", "text": "12:04:33", "role": "body", "monospacedDigit": true, "lineLimit": 1 }
```
`role`: `"title"` | `"body"` (default) | `"caption"` | `"code"`.

### Image

```json
{ "type": "image", "source": { "kind": "sfSymbol", "name": "bolt.fill" }, "size": 16, "tint": "accent" }
```
`source.kind`: `"sfSymbol"` (uses `name`) | `"fileIcon"` / `"fileThumbnail"` (use `path`; thumbnail keys cache on `modifiedAt` epoch-ms).

### Progress (linear / ring, with optional host countdown)

```json
{ "type": "progress", "value": 0.62, "style": "linear", "label": "62%", "tint": "good" }
```
```json
{
  "type": "progress", "style": "ring",
  "countdown": { "from": 1720000000000, "until": 1720000030000 },
  "labelFrom": "remainingSeconds",
  "tintRules": [ { "whenRemainingLtSeconds": 10, "tint": "danger" } ]
}
```
`value` is 0.0–1.0. `countdown` (epoch ms) makes the host tick the ring 1 Hz with
no re-run; `labelFrom: "remainingSeconds"` renders the seconds left; `tintRules`
(first match wins) override `tint`.

### Button (carries an action, see below)

```json
{ "type": "button", "title": "Copy", "icon": "doc.on.doc",
  "action": { "type": "copyText", "value": "hello", "toast": "Copied" } }
```

### Badge / Banner / Empty / Divider / Spacer

```json
{ "type": "badge", "text": "3", "tone": "danger" }
```
```json
{ "type": "banner", "text": "Rate limit reached", "icon": "exclamationmark.triangle", "tone": "warning" }
```
```json
{ "type": "empty", "icon": "tray", "title": "No files", "subtitle": "Nothing to show." }
```
```json
{ "type": "divider" }
```
```json
{ "type": "spacer" }
```

### NodeAction (on `button`, or a node's `action`)

`type` is one of: `copyText`, `openURL`, `openFile`, `revealFile`, `refresh`,
`run`, `event`.

```jsonc
{ "type": "copyText", "value": "…", "toast": "Copied", "clearAfterSec": 30 } // clears clipboard after N s
{ "type": "openURL",  "url": "https://example.com" }
{ "type": "openFile", "path": "~/Downloads/x.pdf" }
{ "type": "revealFile", "path": "~/Downloads/x.pdf" }                         // reveal in Finder
{ "type": "refresh" }                                                        // re-run this widget
{ "type": "run", "command": ["/bin/ls", "-la"], "thenRefresh": true }        // must match permissions.exec
{ "type": "event", "id": "increment", "toast": "…" }                         // script widgets: routed to action handler
```

Any node may also carry `drag: { "filePath": "~/x.png" }` to make the rendered
view draggable out to Finder/other apps.

---

## 11. Registry entry (publishing) — not part of `widget.json`

To list a widget in the gallery, add an entry to `registry/index.json`. That
entry — **not the manifest** — carries `category` (gallery grouping chip) and
`screenshot` (preview image), alongside `id`, `name`, `requires`, `permissions`,
and the install source. See `docs/REGISTRY.md`. Keep it out of `widget.json`.

---

## 12. Build / test loop (the `mbk` CLI)

```bash
mbk new my-widget --kind workflow      # scaffold a valid widget (auto-validates)
mbk validate ./my-widget               # decode widget.json (+workflow.json) via the real Core decoders
mbk install ./my-widget                # install from a local dir (also: GitHub URL, .zip/.mbw, barshelf://install)
mbk list                               # list installed widgets
mbk pack ./my-widget -o my-widget.mbw  # package (adds manifest.sha256)
mbk agent-spec                          # print THIS document
```

- **Dev mode:** BarShelf discovers `./widgets/<name>/widget.json` relative to the
  app's working directory **before** the install directory
  (`~/Library/Application Support/barshelf/widgets/`); on duplicate ids the dev
  copy wins. Drop your widget in `./widgets/` and it loads without installing.
- **Force a refresh** while testing the `"url"` trigger:
  `open "barshelf://refresh?widget=<id>"` (omit `?widget=` to refresh all).
- Exit codes: `0` success, `1` failure; errors go to stderr. Run `mbk validate`
  until it prints `valid:` before installing.

---

## 12A. Worked examples (one per layer)

### A) exec — clock (emits UINode JSON)

`widget.json`
```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.you.clock",
  "name": "Clock",
  "version": "0.1.0",
  "icon": "clock",
  "bucket": { "group": "My Widgets", "size": "S" },
  "entry": { "kind": "exec" },
  "source": { "kind": "exec", "command": ["./widget.sh"], "timeoutMs": 5000, "output": "viewtree" },
  "refresh": { "onOpen": true, "interval": 60, "staleAfterSec": 30 }
}
```
`widget.sh` (chmod +x)
```bash
#!/bin/bash
set -euo pipefail
NOW="$(date '+%H:%M:%S')"
cat <<EOF
{
  "id": "root", "type": "vstack", "spacing": 8,
  "children": [
    { "id": "title", "type": "text", "text": "Clock", "role": "title" },
    { "id": "time", "type": "text", "text": "${NOW}", "role": "body", "monospacedDigit": true }
  ]
}
EOF
```

### B) workflow — HTTPS JSON + wake trigger (R12: `http` source + `network` permission)

`widget.json`
```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.you.gh-status",
  "name": "GitHub Status",
  "version": "0.1.0",
  "icon": "checkmark.seal",
  "bucket": { "group": "My Widgets", "size": "M" },
  "entry": { "kind": "workflow", "main": "workflow.json" },
  "refresh": { "onOpen": true, "interval": 300, "triggers": ["wake"] },
  "permissions": { "network": ["www.githubstatus.com"] },
  "appearance": { "accent": "green", "cardStyle": "tinted" }
}
```
`workflow.json`
```json
{
  "schemaVersion": 1,
  "kind": "workflow",
  "sources": {
    "status": {
      "use": "http",
      "with": {
        "url": "https://www.githubstatus.com/api/v2/status.json",
        "headers": { "Accept": "application/json" }
      }
    }
  },
  "transforms": {
    "desc": { "use": "assign", "from": "$.sources.status.status.description" }
  },
  "view": {
    "type": "vstack", "spacing": 6,
    "children": [
      { "type": "text", "text": "GitHub", "role": "title" },
      { "type": "text", "text": "${transforms.desc}", "role": "body" }
    ]
  }
}
```
Workflow sources: `use` is `"exec"`, `"fs.directory"`, or `"http"`. Values flow
into `${...}` expressions in `transforms`/`view`: reference source output as
`$.sources.<id>.<path>`, transforms as `transforms.<id>`, settings as
`settings.<key>`. Built-in expression functions: `string`, `now`, `count`,
`coalesce`, `date.relative`, `file.basename`, `file.extension`, `text.truncate`.
Built-in transforms (`use`): `assign`, `limit`, `filter`, `sort`. Repeat with
`{ "forEach": "$.transforms.x", "as": "item", "template": { … "${item.field}" … } }`.
Provide an `"empty"` node for the zero-items case.

### C) script — click counter (state + action handler)

`widget.json`
```json
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.you.counter",
  "name": "Counter",
  "version": "0.1.0",
  "icon": "plus.circle",
  "bucket": { "group": "My Widgets", "size": "S" },
  "entry": { "kind": "script", "runtime": "deno-ts@1" },
  "source": { "kind": "script", "output": "viewtree" },
  "refresh": { "onOpen": true, "staleAfterSec": 60 }
}
```
`index.ts`
```ts
import { mb, ui, action, type WidgetLoadContext, type WidgetActionContext } from "barshelf";

async function render(): Promise<void> {
  const count = (await mb.storage.get<number>("count")) ?? 0;
  await mb.render(
    ui.vstack([
      ui.text("Counter", { id: "title", role: "title" }),
      ui.text(String(count), { id: "n", role: "body", monospacedDigit: true }),
      ui.button("Increment", action.event("inc"), { id: "btn" }),
    ], { id: "root", spacing: 8 }),
    { cacheTtlMs: 60_000 },
  );
}

async function load(_ctx: WidgetLoadContext): Promise<void> { await render(); }

async function action_(ctx: WidgetActionContext, event: { id?: string }): Promise<void> {
  if (event.id === "inc") {
    const count = (await mb.storage.get<number>("count")) ?? 0;
    await mb.storage.set("count", count + 1);
    await render();
  }
}

export default mb.widget({ load, action: action_ });
```

---

## 13. Checklist before you ship

- `schemaVersion`, `id` (filesystem-safe), `name`, `entry.kind` present.
- Every command/host you touch is declared in `permissions` (exec allowlist,
  `network` for `http`, `keychain`/`notifications` as needed).
- View tree uses only the 13 rendered node types; lists give each row a stable `id`.
- `mbk validate ./my-widget` prints `valid:`.
- Loads in dev mode from `./widgets/` (or `mbk install ./my-widget`), and the
  first-run permission prompt lists what you expect.
