# BarShelf 0.7.13

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Glass look.** Floating surfaces (toasts, hover hints, the search overlay,
  card controls) use the system's glass on macOS 26 and a lit material
  before it. Reduce Transparency and Increase Contrast get opaque surfaces
  and solid edges. Cards have rounder corners, and widget tiles are lit from
  above.
- **Capsule buttons.** Actions in the popup, on cards and in the gallery are
  capsules that respond to hover and press. Allow still never answers to
  Return.
- **Popup header.** The page position is shown quietly as `1/7`. Refresh All
  and More are round icon buttons with hover hints that show their keys,
  and a search field (⌘F) sits under the header.
- **Search.** Results float in a glass panel with each widget's tile; the
  selected result is filled with the accent and shows ↵.
- **Permission cards** put Deny and Allow on their own row, so the reason is
  no longer squeezed.
- **Toned boxes inside widgets** no longer wash the whole box in colour. The
  numbers and meters carry the colour, and the box keeps a faint edge.
- **Menu bar cluster** (Settings ▸ Menu Bar ▸ Show widgets as: Cluster).
  Promoted widgets become small overlapping discs beside the BarShelf icon,
  with a red dot for a reading in trouble. Pointing at a chip grows it into a
  pill with its reading ("CPU 22%"), a gap opening on each side of it; the
  item widens once when the pointer arrives and stays put while you move
  between chips, then folds back when it leaves. Rest on it to see its reading, click to open its card there, then
  move along or press ← → to switch cards. Widgets can mark their metrics as
  `profiles` (accounts, hosts) to get one chip each.
  Each chip shows what it measures (CPU, memory, power, …) rather than its
  widget's initial, and chips that share a colour (two from one widget) step
  around the colour wheel so they tell apart. When a reading turns to a
  warning, switches on or off, or changes its icon, the chips come forward
  one by one, left to right; at most once every three minutes, never while
  you point at them, and only a brief glow with Reduce Motion. Settings ▸
  Menu Bar ▸ Wave when a widget changes turns it off.
- **Menu bar cards.** The card a menu bar item or cluster chip opens has
  the same shape for every widget: its tile, name and freshness, a named
  button for what clicking the card does ("Open Activity Monitor"),
  Refresh and Settings; then the reading it shows in the menu bar, large,
  beside its last couple of minutes; then the widget itself. A reading that
  has stopped updating is dimmed and says so. The card is a little wider
  and only as tall as its content.
- **System** splits CPU into user and system time, names every figure
  (busiest core, 1-minute load average, memory used of total, pressure,
  disk free) and lists the apps using the most CPU while its card is open,
  with a Quit button that always asks first. It asks once for permission to
  do that. **Sensors** labels its power reading. Readings in their normal
  range are no longer green; colour marks the ones that need attention.
- **For widget authors:** a `sparkline` node, stacked `progress.segments`,
  the busiest processes from the `system` source and a `quitApp` action
  (`permissions.quitApps`). Widget buttons now use BarShelf's capsule style.
- **One way to do things everywhere.** Empty states, buttons, the widget
  menu, the Remove confirmation and the "waiting for your permission" state
  look and read the same on the popup, the Shelf, the gallery, onboarding
  and settings, and every list of widgets shows its tile. Command names
  match ("Create Widget…", "Install Widget from URL…", "Show in Finder").
  The gallery takes ⌘F and ⌘R.
- **Keep Awake** checks the guard once a minute instead of on every one of
  its five-second status writes, which ran a script around the clock.
- **Gallery.** Widgets without a screenshot are drawn as the card they will
  be, not as a symbol on a pastel field. Previews that are still loading show
  the same placeholder rows instead of a spinner.
