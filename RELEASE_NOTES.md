# BarShelf 0.7.3

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Menu bar widgets with the same refresh interval share one timer, which is retained when opening the popup or reloading unchanged settings.
- Nearby widget results are combined before calculating and drawing the menu bar, reducing intermediate updates. Settings changes still apply immediately.
- Shared metric collection stays deduplicated while many file-system paths are in use, and slow collections remain reusable briefly after completing.
