# BarShelf 0.3.10

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Sensors

- **Any single sensor in the menu bar.** The Sensors widget's "Menu bar
  shows" picker now lists every sensor this Mac can read — a specific core,
  the SSD, the ambient sensor, a fan — beside the usual CPU, GPU and battery.
  Only that sensor is read while the card is closed.
- **Two readings in one item.** "Also show" adds a second reading (say, CPU
  and power); choose **Two metric rows** to stack them.
- **Average or hottest.** CPU, GPU and battery can show the hottest of their
  sensors instead of the average.

## System

- **More to put in the menu bar.** Besides CPU, memory and disk, the System
  widget can show CPU user or system time, the busiest core, memory
  pressure, swap used, disk free, and disk read or write speed.
- **Two readings in one item**, like Sensors: "Also show" adds a second.
- Disk speed is only measured while an item shows it.

## Menu bar

- **Choose what a click does.** An item of its own can show its card (as
  before), refresh, open an app or link — Activity Monitor from the CPU
  item, say — or open BarShelf. Its right-click menu keeps "Show Card".
- **Presets and copying.** "Apply Preset" gives an item (or, in Settings →
  Menu Bar, every item) a ready-made look — Compact, Steady, Bold, Minimal,
  Graph — and "Copy From" takes another item's layout and style.

- **Graphs.** An item with its own place in the menu bar can draw a
  sparkline, bars or a gauge of its reading beside the number (Settings →
  Menu Bar → Graph). Percentages are drawn against 0–100; anything else
  against its recent peak. The item keeps one width as the graph fills.

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
