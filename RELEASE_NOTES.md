# BarShelf 0.3.10

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **Your own warning colours.** Each item's settings gain an Alerts row:
  a warning and a danger threshold, in the unit the item shows (%, °C, GB,
  MB/s…), and whether higher or lower is worse. They replace the widget's
  built-in 75/90 colours for that item.
- **Show an item only when it matters.** "Show only at or above" keeps an
  item out of the menu bar until a reading gets there — a fan that appears
  when it spins up, a battery that appears when it runs low. It keeps
  refreshing while hidden, so it comes back on its own.

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
