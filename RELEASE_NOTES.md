# BarShelf 0.7.16

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Script widgets with big outputs are light again.** Reading a command's
  JSON output, and the messages a script widget sends, no longer goes
  through a slow decoder twice; a command's result is handed to the script
  without being encoded and decoded on the way. With four muxa Watch cards
  refreshing every five seconds, BarShelf's CPU fell from about 7% to under 2%.

