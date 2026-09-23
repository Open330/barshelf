# BarShelf 0.3.10

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **A CPU that sat at 100% no longer snaps its item narrow the moment it
  comes down.** 0.3.9 kept a widened item for a minute after the wide
  reading was last *drawn* — but a reading that doesn't change is never
  redrawn, so after a long stretch at 100% the minute had already run out.
  The minute now starts when readings come back down.
