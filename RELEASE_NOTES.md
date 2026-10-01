# BarShelf 0.3.13

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Fixes

- **Updates check your macOS version before installing.** If a new BarShelf
  needs a newer macOS than your Mac runs, the updater says so and leaves the
  installed copy as it is. Before, it would have replaced a working copy with
  one that macOS refuses to open. This has to ship before any release that
  raises the minimum macOS.
