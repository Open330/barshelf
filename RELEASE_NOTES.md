# BarShelf 0.7.16

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Script widgets with big outputs are light again.** Reading a command's
  JSON output, and the messages a script widget sends, no longer goes
  through a slow decoder twice; a command's result is handed to the script
  without being encoded and decoded on the way. With four muxa Watch cards
  refreshing every five seconds, BarShelf's CPU fell from about 7% to under 2%.
- **The shelf board works from the keyboard.** In the BarShelf window's
  Widgets view, the arrow keys choose a widget (left and right move between
  pages), ⌥⌘ and an arrow moves it, Return shows or hides its settings,
  Delete removes it after asking, and Escape clears the choice.
- **Settings choose the same way everywhere.** What a feature does is a
  radio group with a line saying what the chosen option does: Menu Bar ▸
  Show widgets as now matches Dock ▸ BarShelf Dock, which gained its line.

