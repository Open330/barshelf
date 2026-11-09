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
