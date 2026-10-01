# BarShelf 0.4.1

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **Gallery:** a standard search field with a result count, plus Type (Command / Workflow / Script) and Category pickers. A search with no results offers Clear Search.
- **Gallery:** click a widget, or press Return on it, to open its detail page. The page shows a large preview, the full description, every permission written out in plain language, which required tools are installed (with the install command for common ones), and links. From there you can Install, Update, Open, or Remove… it. Esc goes back.
- **Gallery:** Install from URL… and Create Widget buttons sit above the grid, and the refresh button shows when it is loading.
- **Gallery:** the two sections are now called "BarShelf Widgets" and "Connected Widgets", with plain descriptions.
- **Gallery:** stops watching for installs while its window is minimized or covered, so an open Gallery no longer uses CPU in the background (#1).
