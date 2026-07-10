# BarShelf 0.1.1

A big quality pass on top of 0.1.0: a curated set of **native-looking widgets**, a
much more capable **visual builder**, clickable widgets, and a lot of polish. The
app is Developer ID–signed and Apple-notarized — double-click to open.

> Requires macOS 13+ on Apple Silicon. Script widgets need [Deno](https://deno.land)
> (`brew install deno`); exec and workflow widgets work without it.

## Highlights

- **Native widget gallery** — a curated set styled like real macOS/iOS widgets:
  content-based color, per-widget accent, and a Fit / fixed-height layout.
  Today · Calendar · Clock · Weather · Exchange · Stock · Battery · System ·
  Network · Recent Files · aas Usage · OTP Codes · muxa Watch · Downloads ·
  GitHub Status · Reminders · Now Playing.
- **Clickable widgets** — like a real widget, clicking a card opens its companion
  app or page (Today → Calendar, System → Activity Monitor, Stock → Yahoo
  Finance, Weather → Weather app, …) via a new `openApp` action.
- **In-app management** — hub window, drag to reorder / reposition widgets,
  per-card edit button, pin, disable, and move-to-panel.
- **OTP service icons** — OTP Codes rows lead with the service's favicon
  (letter-tile fallback), fetched only through the widget's declared network
  allowlist and switchable off with a "Show service icons" setting.

## Visual builder

- **More sources** — run a command, a shell **pipeline** (now correctly run under
  `/bin/sh -c`), an HTTP JSON endpoint with request headers, a watched folder, or
  pasted/static JSON.
- **Richer displays** — list, table, single value, plain text, and **meters**:
  add multiple meters, each a **Bar** or **Ring**, grouped into a panel.
- **Native list rows** — an optional **secondary line** (subtitle) and **trailing**
  right-aligned value, plus a **local search field** that filters rows without a
  re-run.
- **Refine** — filter / sort / limit and a per-row click action.
- **Readable permissions** — the approval card summarizes what a widget runs
  (e.g. "Run system tools: df, top, memory_pressure") instead of a raw script.

## Workflow engine

- Per-widget **storage / persistence** (KV + TTL), a **switch** conditional node,
  logic & arithmetic functions, string literals, and array-index paths.

## Fixes

- Shell `${var}` no longer collides with workflow `${expr}` interpolation.
- Shell/exec widgets get a sane `PATH`; battery/system/network/calendar use
  absolute tool paths and read reliably.
- Removed the duplicated card header; reliable card heights across sizes.
- Drag-to-reorder now shows a preview and a drop indicator.

## Notes

- The bundled CLI is now `barshelf` (was `mbk`).

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.1.0...v0.1.1
