# BarShelf 0.6.1

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.6.1 lets you refresh a desktop widget right where it sits, adds an
extra-large size, and lets widget authors say how their widget should look on
the desktop.

## Changes

- **Refresh from the desktop.** Medium and larger desktop widgets have a ↻
  button in their header; in the small size, the orange clock that marks an
  old reading is the button. The widget shows that it is refreshing and
  updates as soon as BarShelf has the new reading.
- **Extra large.** Desktop widgets come in an extra-large size: lists and
  meters in two columns, and up to twelve file thumbnails.
- **A tip on the Shelf** says how to put BarShelf on your desktop, until you
  dismiss it.
- **For widget authors:** `desktop.style` picks the layout BarShelf uses on
  Automatic, `desktop.offer: false` keeps a widget off the desktop list, and
  `desktopRole` on any node marks items (`item`), sets the title, value,
  detail, or status, or leaves a node out (`hide`). See WIDGET-SPEC and
  AGENTS.md §8B. Older versions of BarShelf ignore them.
