# BarShelf 0.7.15

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Menu bar cluster answers intent, not just position.** Chips open once
  the pointer rests on them for a moment, so a pointer crossing the menu bar
  on its way to another item no longer widens the cluster. They stay open
  while the pointer drifts a few points below or past the item, and fold
  only after it has been away for a third of a second (longer when it went
  down to read a peek). Folding is a little slower than opening, and Reduce
  Motion skips the glide.
- **Less work at rest.** The menu bar image is replaced only when it would
  look different (folded chips do not show their readings), and it is drawn
  once into a bitmap instead of again for every display's menu bar.
  Permission checks no longer re-hash every widget on each menu bar update.
  `scripts/profile-idle.sh` measures and profiles the running app.
- **Card controls no longer cover the card.** On a card with a header,
  Refresh and Settings appear in the header on hover, in place of the "3m
  ago" time, so nothing floats over the title or the content. Cards without
  a header, and half-width cards, show one small `⋯` menu in the corner
  instead. Drag a card by its icon and name to reorder it.
