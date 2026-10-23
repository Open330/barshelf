# BarShelf 0.7.4

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **BarShelf stays light after days of running.** A closed popup kept its
  view alive and re-measured it on every widget refresh, and macOS leaked a
  little memory on each pass: after four days BarShelf used 3–10% CPU and
  about 270 MB while idle, against under 2% and about 30 MB just after launch.
  The popup now lets go of its view when it closes and builds it again when it
  opens.
