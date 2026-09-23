# BarShelf 0.3.9

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **Power lines up with CPU and RAM.** Units like `W`, `V` and `°C` now sit
  against their number (`12W`), the way `%` and `°` always have; word units
  such as `rpm` keep their space. The space in `12 W` was the whole reason a
  power item stood 3 pt wider than its neighbours — `W` is exactly as wide as
  `%`.

- **Tighter menu bar items.** Each item now takes exactly the width of what it
  draws with one point either side, instead of three plus the button's own
  inset. On a CPU / RAM / power setup the three items go from 44, 36 and
  39 pt to 32 pt each — 23 pt of menu bar back.

- **A spike no longer widens an item for the rest of the day.** An item that
  once needed more room (CPU at 100%) kept that width until the next restart.
  It now keeps it for a minute after a reading last needed it, then returns to
  its usual width — still steady for a reading hovering at 99/100.
