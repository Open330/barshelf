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
  with a red dot for a reading in trouble. Pointing at one uncovers just that
  chip in place, without widening the item or covering anything else in the
  menu bar. Rest on it to see its reading, click to open its card there, then
  move along or press ← → to switch cards. Widgets can mark their metrics as
  `profiles` (accounts, hosts) to get one chip each.
- **Gallery.** Widgets without a screenshot are drawn as the card they will
  be, not as a symbol on a pastel field. Previews that are still loading show
  the same placeholder rows instead of a spinner.
