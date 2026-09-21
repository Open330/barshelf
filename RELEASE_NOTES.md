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

## Menu bar API

- **A widget can now name its own icon and colour, per refresh.** Both were
  manifest-only, which meant neither could follow a value — a battery icon
  could not track its level, and a reading could not go red when it mattered.
  `status.icon` takes an SF Symbol name and `status.tint` one of `accent`,
  `good`, `warning`, `danger`, `secondary` — the same words the view layer
  uses, so a widget says `danger` in one vocabulary rather than two. Script
  widgets get both through `host.render`'s status.

  Leave the tint off unless the colour carries meaning: without one the item is
  a template image, which follows a light or dark menu bar and inverts while
  held open, and a fixed colour trades both away. An unknown name loses the
  colour, not the reading.

  The bundled **System** and **Sensors** widgets use it — their menu bar
  readings turn orange past 75% and red past 90%, matching the thresholds their
  cards already drew.
