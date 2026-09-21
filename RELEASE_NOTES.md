# BarShelf 0.3.2

> Unreleased — this file describes the next release and is added to as work
> lands. Requires macOS 13+ on Apple Silicon.

## Fixes

- **An update that installs but never runs is now reported, not celebrated.**
  A replaced app can produce a process that holds a pid and never executes —
  macOS refused one outright, 32 KB resident and parked in `_dyld_start` — and
  the updater took that pid as proof, quit the build that was working, and
  reported success. One machine went a day with an empty menu bar.

  BarShelf now writes a launch receipt once its menu bar item exists, and both
  updaters wait for it. `barshelf upgrade --restart` fails with "was updated but
  did not start" while making clear the install itself succeeded.
  **Check for Updates…** goes further and does not quit at all until the
  replacement checks in — a few seconds of two menu bar icons costs far less
  than the app vanishing.

- **And the update is undone when it cannot run.** Proving the replacement
  works is only half of it; the other half is not leaving a build that macOS
  refuses to launch as the only thing on disk. The superseded bundle is now
  kept beside the new one until the new one checks in, then discarded — or put
  back. `barshelf upgrade` says which of the two happened, because it changes
  whether you have anything to do.

  Checking *before* the swap would not have helped: the copy that macOS refused
  was refused for its destination path, and the identical bundle launched from
  a staging directory came up perfectly. It has to be tried where it will live.

  This protects updates *from* 0.3.2 onward; moving off 0.3.1 still uses the
  old path.

## Menu bar

- **Label and icon are yours to set, on any widget.** A short label is drawn
  before the value the way a system monitor writes `CPU 23%`, and the icon
  takes an SF Symbol name *or an emoji* — 🌡️ works, because the menu bar draws
  it as text. Leave the icon empty for the widget's own, or turn it off
  entirely. Both live in Settings ▸ Menu Bar, next to the existing choice
  between sharing the BarShelf item and taking one of your own.

- **Sensors reads far more of the machine.** The menu bar can now show power
  draw, fan speed and fan load alongside the four temperatures, and the card
  lists every sensor the Mac exposes — 118 readings on the MacBook Air this was
  built on — hottest first.
