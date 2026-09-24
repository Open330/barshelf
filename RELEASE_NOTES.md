# BarShelf 0.3.11

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Performance

- **Graphs cost about 40% less.** A graph now takes one point every 5
  seconds (the highest reading in between), so an item whose number sits
  still no longer repaints on every refresh, and a gauge repaints only when
  its ring would visibly move. With graphs, alerts, a picked sensor and
  second readings all on, BarShelf went from 2.1% to 1.3% of a CPU core.
- **Widget expressions evaluate only what they need.** `if`, `and`, `or`,
  `coalesce` and `default` no longer compute branches they discard — a
  reading picked from a dozen options used to compute all twelve.

## Widgets

- **Widgets can say which BarShelf they need.** A widget can declare
  `minHostVersion`; on an older BarShelf it now says "Needs BarShelf X or
  later" instead of running and showing "—", and installing it is refused
  with the same reason (in the app and in `barshelf install`).
- **New expression functions: `switch` and `get`.** `switch(value, case,
  result, …, fallback)` picks one of many readings by a setting without a
  dozen nested `if`s; `get(object, key)` reads a field chosen at run time.
  The System and Sensors widgets (0.5.1) are rewritten with them.
## Settings

- **A widget's menu bar settings are in three tabs** — Look, Readings and
  Behavior — instead of fourteen rows in one column. The preview stays above
  them.

## Fixes

- **Graphs survive an update or a quick relaunch.** Graph history is saved
  every 30 seconds and at quit, so after an in-app update or a restart
  within a minute each graph picks up where it was; after a longer gap it
  starts fresh rather than joining old points to new. Widgets that keep
  their output off disk are never saved.

- **Network and disk speeds no longer spike after sleep.** Their rates were
  timed on a clock that stops while the Mac sleeps, so traffic from a night
  of dark wakes was divided by a few seconds on the first refresh after
  waking. They now use a clock that counts sleep, and a long gap starts a
  fresh measurement instead.
