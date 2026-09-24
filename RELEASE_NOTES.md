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

## Fixes

- **Network and disk speeds no longer spike after sleep.** Their rates were
  timed on a clock that stops while the Mac sleeps, so traffic from a night
  of dark wakes was divided by a few seconds on the first refresh after
  waking. They now use a clock that counts sleep, and a long gap starts a
  fresh measurement instead.
