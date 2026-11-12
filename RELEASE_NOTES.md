# BarShelf 0.7.32

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Errors and confirmations work the same everywhere. Install failures, the menu bar tooltip, VoiceOver, the Dock, the builder's Test, update checks and settings saves now say what happened and what to do, with the raw message kept behind Details. A widget button that fails shows its own message instead of marking the card's reading as stale. The Dock and the BarShelf window now show confirmations (Copied, Moved, Removed with Undo), a refresh that can't run says why, and replacing a saved Apple Dock layout or unsaved automation edits asks first.
- Settings and the Shelf look and behave the same everywhere: every page has a header with figures that say something (General, Updates and Automation got theirs), on/off rows are switches on the right, the widget inspector lines its controls up in one column, the Shelf wraps its pages instead of cutting the last one off, and the Shortcuts page now lists every key, including ⌘E, the Shelf's keys and the Dock's. The Gallery has one Everyday filter, translated packs, "Install All" buttons, labelled permission chips, and stays put after an install with a "Show in Shelf" notice.
