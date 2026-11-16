# BarShelf 0.7.40

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- A widget that can't run at all — its command isn't one it has permission for, or it is a kind this BarShelf doesn't know — is no longer tried again on every tick of its timer. It waits 15 seconds, then a minute, then five, like any widget that keeps failing, instead of adding a line to the audit log each time. Refresh still tries at once, and so does the widget after you fix its `widget.json`.
