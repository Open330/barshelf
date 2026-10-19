# BarShelf 0.7.2

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.7.1 makes ⌘Space input switching reliable and warns when an
Automation shortcut is also a macOS shortcut.

## Changes

- **Input source switching that sticks.** `barshelf.selectNextInputSource()`
  now hands the switch to macOS when the system's "Select next source in Input
  menu" shortcut is set to a key with no modifier, such as F18: BarShelf sends
  that key and macOS switches at once, in the app you are typing in. Before,
  switching directly could change the menu bar while the focused app kept
  typing in the old language with Korean, Japanese, or Chinese input. Without
  such a shortcut it switches directly, as before. See AUTOMATION.md.
- **Shortcut conflicts are shown.** The Automation page warns when one of your
  bindings uses the same keys as an enabled macOS shortcut — both would run, so
  ⌘Space would switch twice and end where it started — and opens Keyboard
  Shortcuts in System Settings.
