# BarShelf 0.7.15

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Menu bar cluster answers intent, not just position.** Chips open the
  moment the pointer reaches them and stay open while it drifts a few points
  below or past the item. They fold a fifth of a second after it has gone
  (a little longer when it went down to read a peek). Folding is a little
  slower than opening, and Reduce Motion skips the glide.
- **Less work at rest.** The menu bar image is replaced only when it would
  look different (folded chips do not show their readings), and it is drawn
  once into a bitmap instead of again for every display's menu bar.
  Permission checks no longer re-hash every widget on each menu bar update.
  `scripts/profile-idle.sh` measures and profiles the running app.
- **Fewer and cheaper waves.** A chip that turns to a warning and back
  before the wave's cooldown ends no longer sets off a wave three minutes
  later. Chip glyphs are drawn once per size instead of on every frame of the
  wave and the hover glide. Switching apps no longer lists every running app
  for the dock.
- **Lighter dock.** Moving the pointer along the dock rebuilds only the
  icons that change (the ones growing under it), not every icon and its
  menu. Icons and names are read once every ten minutes instead of every
  minute, and again when an app launches.
- **Card controls no longer cover the card.** On a card with a header,
  Refresh and Settings appear in the header on hover, in place of the "3m
  ago" time, so nothing floats over the title or the content. Cards without
  a header, and half-width cards, show one small `⋯` menu in the corner
  instead. Drag a card by its icon and name to reorder it.
