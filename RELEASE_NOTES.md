# BarShelf 0.3.11

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Fixes

- **Network and disk speeds no longer spike after sleep.** Their rates were
  timed on a clock that stops while the Mac sleeps, so traffic from a night
  of dark wakes was divided by a few seconds on the first refresh after
  waking. They now use a clock that counts sleep, and a long gap starts a
  fresh measurement instead.
