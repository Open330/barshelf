<div align="center">

<img src="assets/media/icon-512.png" width="128" alt="BarShelf" />

# BarShelf

**Your menu bar, finally organized.**

One menu bar icon. Every glanceable tool you care about — OTP codes, LLM usage,
recent files, CI status — as native widgets in a single popover.

[![Platform](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Notarized](https://img.shields.io/badge/Developer%20ID-notarized-2E7D32?logo=apple&logoColor=white)](https://github.com/Open330/barshelf/releases/latest)
[![Dependencies](https://img.shields.io/badge/dependencies-zero-4c1)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[**Download**](https://github.com/Open330/barshelf/releases/latest) ·
[**Getting Started**](docs/GETTING-STARTED.md) ·
[**Build a Widget**](docs/WIDGET-SPEC.md) ·
[**Publish**](docs/PUBLISHING.md)

<!-- 스크린샷 자리: 메뉴바 아이콘 + 열린 팝오버(위젯 여러 개) -->

</div>

---

## Why BarShelf

Your most-checked tools are scattered — a dozen menu bar icons, terminal windows,
browser tabs. BarShelf collects them into **one icon, one popover** of native
widgets. Any command-line tool you already have becomes a widget in minutes; no
new SDK to learn.

- **🪟 One icon, many widgets** — bucket pages, trackpad swipe, pinned row, ⌘F search.
- **⚡ CLI is the API** — `aas usage --json`, `otpeek`, `gh`, `kubectl`… pipe them straight in.
- **🎨 Native, not web** — SwiftUI rendering, dark mode, SF Symbols, vibrancy. No Electron.
- **🧩 Three ways to build** — declarative workflows, a Shortcuts-style visual builder, or full scripts.
- **🔒 Signed & notarized** — opens by double-click; every widget is permission-gated with an audit log.

## Three execution layers, one widget model

Every widget shares the same scheduler, permission frame, and native renderer —
it only differs in where its data comes from:

```
┌────────────────────────────────────────────────────────────────┐
│  exec       manifest declares a CLI → UINode view tree          │
│             (viewtree direct, or data + a builtin adapter)      │
│                                                                  │
│  workflow   declarative JSON DSL — sources → transforms → view  │
│             (${…} interpolation, forEach, fs.directory + QL      │
│              thumbnails, drag-out) — no code                    │
│                                                                  │
│  script     resident Deno subprocess over JSON-RPC + TS SDK     │
│             host-mediated exec / storage / secret / timer       │
└────────────────────────────────────────────────────────────────┘
```

## Install

Grab `BarShelf-<version>-arm64.zip` from
**[Releases](https://github.com/Open330/barshelf/releases/latest)**, move it to
`/Applications`, and **double-click** — the build is Developer ID signed and
Apple-notarized, so there's no Gatekeeper dance.

Full guide, `mbk` CLI, and troubleshooting: **[docs/INSTALL.md](docs/INSTALL.md)**.

> Requires macOS 13+ on Apple Silicon. Script widgets need [Deno](https://deno.land)
> (`brew install deno`); exec and workflow widgets work without it.

## Bundled widgets

| Widget | Layer | What it shows |
|---|---|---|
| **hello** | exec (viewtree) | The smallest widget — a shell script emitting a UINode tree. |
| **aas Usage** | exec (data + adapter) | LLM account usage meters from [`aas usage --json`](https://github.com/Open330/aas). |
| **OTPeek** | exec (data + adapter) | TOTP codes with a countdown ring; Keychain-injected vault password. |
| **Recent Files** | workflow (`fs.directory`) | Stashbar-style recent files with QuickLook thumbnails and drag-out. |
| **Script Clock** | script (Deno) | Live clock + storage-backed click counter via the TypeScript SDK. |

## Build a widget in 3 minutes

**Visual builder** — status menu → *Create Widget…* → pick a source (run a
command / watch a folder / static text), a display (list · table · value · text)
with a **live preview**, then name it. No JSON.

**By hand** — a widget is a folder with a `widget.json`:

```jsonc
{
  "$schema": "https://barshelf.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.docker-ps",
  "name": "Docker",
  "icon": "shippingbox",
  "bucket": { "group": "Dev", "size": "M" },
  "entry": { "kind": "exec" },
  "source": { "kind": "exec", "command": ["docker", "ps", "--format", "json"], "output": "viewtree" },
  "refresh": { "onOpen": true, "interval": 30 },
  "permissions": { "exec": [{ "command": "docker", "allowedArgs": [["ps", "--format", "json"]] }] }
}
```

Drop it in `~/Library/Application Support/barshelf/widgets/` (hot-reloaded), or
install straight from a repo:

```bash
mbk install https://github.com/Open330/aas       # GitHub repo
mbk install ./MyWidget.mbw                        # packed archive
open "barshelf://install?url=…"                   # deep link (README badge)
```

## `mbk` — the widget CLI

```bash
mbk new my-widget --kind workflow   # scaffold from a template
mbk validate ./my-widget            # check manifest + workflow
mbk pack ./my-widget -o my.mbw      # zip a distributable bundle
mbk install <url|path>              # install from repo / archive / deep link
mbk list                            # installed widgets
```

Reference: **[docs/MBK.md](docs/MBK.md)**.

## Documentation

| Doc | Contents |
|---|---|
| [Getting Started](docs/GETTING-STARTED.md) | Install, first widget, the bundled examples |
| [Install](docs/INSTALL.md) | Release install, `mbk`, source build, troubleshooting |
| [Widget Spec](docs/WIDGET-SPEC.md) | `widget.json`, UINode nodes, actions, refresh, permissions |
| [Workflow DSL](docs/WORKFLOW.md) | Sources, transforms, interpolation, built-ins, `forEach` |
| [Script Runtime](docs/SCRIPT-RUNTIME.md) | Deno JSON-RPC protocol, `mb.*` SDK, sandboxing |
| [Publishing](docs/PUBLISHING.md) | Repo layout, install badges, registry submission |
| [Registry](docs/REGISTRY.md) | The curated gallery index and how to list a widget |
| [MBK](docs/MBK.md) | CLI reference |

JSON Schemas: [`widget-0.1.json`](schema/widget-0.1.json) ·
[`uinode-0.1.json`](schema/uinode-0.1.json) ·
[`workflow-0.1.json`](schema/workflow-0.1.json) ·
[`registry-0.1.json`](schema/registry-0.1.json).

## Design principles

- **Zero runtime dependencies** — pure Swift / AppKit / SwiftUI. Deno is optional, script-only.
- **Process isolation is the trust boundary** — third-party widget code never runs in the app process.
- **Declare → approve → enforce** — permissions are shown and approved on first run, then enforced with an audit log.
- **The UI never blanks** — last-good render is always kept; failures show a banner, not an empty popover.

## Build from source

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build   # dev
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # 161 tests
bash scripts/build_app.sh                                              # dist/BarShelf.app + dist/mbk
```

The package splits into `MenubucketCore` (models, manifest/workflow parsing,
schedule policy — UI-free, tested) and `MenubucketApp` (AppKit shell, SwiftUI
renderer, runtime), with a standalone `mbk` executable target.

## License

MIT © Jiun Bae — see [LICENSE](LICENSE).

<div align="center">
<sub>Built with <a href="https://claude.com/claude-code">Claude Code</a></sub>
</div>
