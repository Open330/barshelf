# BarShelf 0.2.0

Widgets can now show a live value in the menu bar, and the system readings
behind them are read natively instead of shelling out.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **Live values in the menu bar** — opt a widget in and its status text updates
  right on the bar, next to the BarShelf mark (`✦ 21% · 46°`). Widgets share
  one status item by default, keeping the one-icon promise; any of them can be
  split onto its own item. Turn them on from the BarShelf icon's right-click
  menu under **Menu Bar ▸**, or in a widget's Settings. Nothing appears there
  until you ask for it.
  A promoted widget keeps refreshing while the popup is closed; **Pause When
  Closed** still stops it, and the menu bar dims a value it can no longer keep
  current rather than passing it off as live.
- **BarShelf can update itself** — when a new release is out, *Check for
  Updates…* can download and install it, then relaunch. The download is only
  accepted if it is signed by the same Developer ID as the build asking to be
  replaced, and macOS is asked for its own verdict before anything is swapped;
  any failure leaves the installed copy untouched and falls back to the release
  page. The copy Homebrew installed is left to `brew upgrade --cask barshelf`,
  an App Store build is left to the Store, and a locally built copy is never
  replaced, because it carries no release identity to verify an update against.
- **New — Sensors widget** — hardware temperatures, fans, and power draw from
  the SMC, with the Apple Silicon HID sensor plane as a fallback. Every reading
  is optional: a fanless Mac lists no fans, and a Mac that publishes nothing
  says so instead of showing a plausible-looking 0 °C.
- **System widget rebuilt** — CPU, memory, and disk now come from Mach
  directly. It no longer runs `top` and `memory_pressure` through a shell, so
  it needs no command permission and a full reading costs about 9 ms instead of
  roughly a second of CPU. Memory joins CPU and disk as a third meter.
- **User-picked folders read correctly** — a widget that exposes a `directory`
  setting can be pointed at any folder without the read being blocked.
  Choosing the folder is the grant, so it no longer has to be pre-declared in
  `permissions.readPaths`, and the "Showing cached data: file source path is
  not covered by permissions" fallback is gone. The pick is still
  symlink-canonicalized and cannot reach outside itself, and a manifest
  `default` cannot self-grant.
- **New — Codex Reset widget** — an unofficial forecast of a Codex quota reset
  in the next 48 hours, from willcodexquotareset.com: a 0–100 score tinted at
  the 70/40 marks. Find it under the custom collection in the gallery.

## For widget authors

- **`system` workflow source** — `cpu`, `memory`, `disk`, and `sensors`
  readings with no subprocess, gated by a new `permissions.system` declaration.
  See [`docs/WORKFLOW.md`](https://github.com/Open330/barshelf/blob/main/docs/WORKFLOW.md).
- **`statusItem` is live** — the menu-bar text is the value a widget already
  computes (a workflow's `status.label`, a script's `host.render` status).
  Declaring a mode marks the widget eligible; the user turns it on. See
  [`docs/WIDGET-SPEC.md`](https://github.com/Open330/barshelf/blob/main/docs/WIDGET-SPEC.md).
- **`concat()`** joins strings inside an expression, which is what a
  conditional unit needs (`'—'` versus `'45.6 °C'`).

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.1.3...v0.2.0
