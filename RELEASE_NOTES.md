# BarShelf 0.7.41

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Removing a widget now removes it for good even when a second folder with the same widget was sitting in the widgets folder (a hand-made copy, for example). Before, the copy took its place right away, with the settings gone and asking for approval again. The second folder goes to the Trash, so nothing you put in it is lost.
- A widget that watches a folder stops watching it when you turn the widget off or remove it. The watch used to stay open in the background.
- Pressing Refresh on a script widget while BarShelf was rescanning the widgets folder now refreshes it right then. It used to be forgotten and then run later, after some unrelated refresh.
