# BarShelf 0.3.10

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **One style for every item.** Settings › Menu Bar sets width, digits,
  alignment, text size and weight, number alignment and colour for all menu
  bar items at once. An item's own settings still win; the app-wide style
  wins over a widget's defaults. "Use These for All" clears the items that
  set their own, keeping their labels, icons and row order.

- **A CPU that sat at 100% no longer snaps its item narrow the moment it
  comes down.** 0.3.9 kept a widened item for a minute after the wide
  reading was last *drawn* — but a reading that doesn't change is never
  redrawn, so after a long stretch at 100% the minute had already run out.
  The minute now starts when readings come back down.
