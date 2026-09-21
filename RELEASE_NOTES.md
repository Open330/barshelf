# BarShelf 0.3.3

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Fixes

- **The stacked menu bar item is drawn properly.** 0.3.2 built its two rows as
  an attributed string, and all three of its visible faults came from that: the
  label's ascenders were cropped ("Power" lost its top) because two
  differently-sized lines were clamped into the bar's height; the text stayed
  black instead of following a light or dark menu bar, since an attributed
  string keeps the colour it is given; and the rows were centred against the
  layout width rather than aligned to the item's left edge.

  Both rows and the icon are now drawn into a single **template image**, which
  the status item tints for itself — so it follows the menu bar, and inverts
  while the item is held open. Each row is placed at a measured origin, so they
  share a left edge and nothing is clipped, and the type is scaled to whatever
  height the bar actually is rather than to an assumed 22 points.
