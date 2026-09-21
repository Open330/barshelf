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

  This protects updates *from* 0.3.2 onward; moving off 0.3.1 still uses the
  old path.
