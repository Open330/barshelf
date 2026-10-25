# BarShelf 0.7.7

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.7.7 makes the first minutes calmer and says when input
switching didn't work.

## Changes

- **A calmer first run.** Your first widgets start together on one page. A
  widget waiting for your OK shows one quiet row — a lock, what it asks, Deny
  and Allow — instead of a banner, a list and a button bar, and the BarShelf
  window marks it with a lock rather than a warning sign. The welcome card and
  setup say the same in fewer words.
- **A tidier gallery.** Browse by category from a row of chips; the widget
  type moved to a small menu. Every card has the same preview band — the
  widget's screenshot shown whole, or its color and symbol — so the grid
  lines up.
- **The shelf board shows readings.** Each widget in the BarShelf window
  shows its current value, such as a battery level, where it has one.
- **Input switching that didn't take is explained.** When ⌘Space input
  switching doesn't change the input source — macOS stopped answering, or its
  shortcut settings can't be read — Automation says so and what to do,
  instead of failing silently.
