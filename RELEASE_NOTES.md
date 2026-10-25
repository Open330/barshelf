# BarShelf 0.7.8

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Desktop widgets update after every update, for real.** 0.7.6 meant to
  restart the widget extension left from before an update, but an update
  removes that extension's file, and BarShelf then failed to recognize it, so
  desktop widgets could keep drawing with the old version. BarShelf now
  recognizes it by name and restarts it when it launches.
