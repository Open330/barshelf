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

<img src="assets/media/popover.png" width="360" alt="BarShelf popover with native Today, Battery, Weather, and aas usage widgets" />

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

## Quickstart for Agents

<div><img src="https://quickstart-for-agents.vercel.app/api/header.svg?theme=claude-code&logo=BarShelf&title=Install+BarShelf+and+build+my+first+widget&lang=Agents&mascot=hat" width="100%" /></div>

```prompt
Install BarShelf on my Mac and scaffold my first widget.

1. Download the latest release from
   https://github.com/Open330/barshelf/releases/latest, unzip the
   BarShelf-<version>-arm64.zip, move BarShelf.app into /Applications, and open it.
2. Download the barshelf CLI — it ships as a separate release asset
   (barshelf-cli-<version>-arm64.tar.gz). Extract it and put barshelf on my PATH.
3. Scaffold a widget:  barshelf new my-widget --kind workflow
   then validate it:   barshelf validate ./my-widget
   then install it:    barshelf install ./my-widget
4. Confirm the widget appears in the menu bar popover.

Requires macOS 13+ on Apple Silicon. Script widgets also need Deno (brew install deno).
```
<div><img src="https://quickstart-for-agents.vercel.app/api/footer.svg?theme=claude-code&tokens=1.2k&model=Opus+4.8&project=barshelf" width="100%" /></div>

Copy the prompt above and paste it into your AI agent to install BarShelf and
scaffold a widget. Prefer the manual steps? The human install guide is right below.

## Install

Grab `BarShelf-<version>-arm64.zip` from
**[Releases](https://github.com/Open330/barshelf/releases/latest)**, move it to
`/Applications`, and **double-click** — the build is Developer ID signed and
Apple-notarized, so there's no Gatekeeper dance.

Full guide, `barshelf` CLI, and troubleshooting: **[docs/INSTALL.md](docs/INSTALL.md)**.

> Requires macOS 13+ on Apple Silicon. Script widgets need [Deno](https://deno.land)
> (`brew install deno`); exec and workflow widgets work without it.

## Gallery widgets

Native widgets ship in the gallery — most are declarative **workflows**
(no code), styled like native macOS/iOS widgets with per-widget color and a
Fit / fixed-height layout. **Today** and **Recent Files** are seeded on first run.

| Widget | Source | What it shows |
|---|---|---|
| **Today** · **Calendar** · **Clock** | `/bin/date` | Big date, a month grid with today circled, a live clock — layout adapts to widget size. |
| **Weather** · **Exchange** · **Stock** | http | Temperature, USD→KRW, and a stock quote (Stock needs a `User-Agent` header). |
| **Battery** · **System** · **Network** | shell | Battery %, CPU/Memory/Disk meters, and the local IP. |
| **Recent Files** | `fs.directory` | Stashbar-style Grid/List of recent files — QuickLook thumbnails, drag-out, click to open. |
| **aas Usage** · **OTP Codes** | CLI | LLM usage meters from [`aas`](https://github.com/Open330/aas); TOTP codes with a countdown ring from [`otpeek`](https://github.com/jiunbae/otpeek). |
| **muxa Watch** | CLI + script | Local and SSH-host [`muxa`](https://github.com/Open330/muxa) agents, grouped by host in compact `NAME / ST / ACT / LAST PROMPT` tables. |
| **Downloads** · **GitHub Status** | mixed | Persistence ("new since last check" counting) and an HTTPS status feed. |

For **muxa Watch**, enter aliases such as `jiun-mbp, jiun-mini, rtzr` in the
*SSH hosts* setting. It uses your existing `~/.ssh/config` and key-based access
in non-interactive mode; remote hosts need muxa v0.8.18 or newer.

Most native widgets are **clickable** — like a real macOS/iOS widget, clicking the card opens its companion app or page (Today → Calendar, System → Activity Monitor, Stock → Yahoo Finance, Weather → Weather app, …).

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
barshelf install https://github.com/Open330/aas       # GitHub repo
barshelf install ./MyWidget.mbw                        # packed archive
open "barshelf://install?url=…"                   # deep link (README badge)
```

## `barshelf` — the widget CLI

```bash
barshelf new my-widget --kind workflow   # scaffold from a template
barshelf validate ./my-widget            # check manifest + workflow
barshelf pack ./my-widget -o my.mbw      # zip a distributable bundle
barshelf install <url|path>              # install from repo / archive / deep link
barshelf list                            # installed widgets
```

`bsf` is the same CLI as a shorter alias.

Reference: **[docs/CLI.md](docs/CLI.md)**.

## Documentation

| Doc | Contents |
|---|---|
| [Getting Started](docs/GETTING-STARTED.md) | Install, first widget, the bundled examples |
| [Install](docs/INSTALL.md) | Release install, `barshelf`, source build, troubleshooting |
| [Widget Spec](docs/WIDGET-SPEC.md) | `widget.json`, UINode nodes, actions, refresh, permissions |
| [Agents](docs/AGENTS.md) | Self-contained widget-authoring spec for LLM agents (also `barshelf agent-spec`) |
| [Workflow DSL](docs/WORKFLOW.md) | Sources, transforms, interpolation, built-ins, `forEach` |
| [Script Runtime](docs/SCRIPT-RUNTIME.md) | Deno JSON-RPC protocol, `barshelf.*` SDK, sandboxing |
| [Publishing](docs/PUBLISHING.md) | Repo layout, install badges, registry submission |
| [Registry](docs/REGISTRY.md) | The curated gallery index and how to list a widget |
| [CLI](docs/CLI.md) | CLI reference |

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
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # 220 tests
bash scripts/build_app.sh                                              # dist/BarShelf.app + dist/barshelf + dist/bsf
```

The package splits into `MenubucketCore` (models, manifest/workflow parsing,
schedule policy — UI-free, tested) and `MenubucketApp` (AppKit shell, SwiftUI
renderer, runtime), with standalone `barshelf` and `bsf` CLI executable targets.

## License

MIT © Jiun Bae — see [LICENSE](LICENSE).

<div align="center">
<sub>Built with <a href="https://claude.com/claude-code">Claude Code</a></sub>
</div>
