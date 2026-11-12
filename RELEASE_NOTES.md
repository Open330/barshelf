# BarShelf 0.7.36

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Your settings survive a file BarShelf can't read. Widget preferences, permission decisions and app preferences are now read value by value, so one value written by a newer version no longer resets everything else. A file that can't be read at all is kept beside the new one (its name gets "corrupt" and the date), and BarShelf tells you. A settings change that can't be saved now says so instead of being lost quietly.
- The audit log (`~/Library/Logs/BarShelf/audit.log`) no longer grows without limit. Commands a widget runs on its own schedule are written once every 10 minutes with a count of the runs in between, and the file rotates at 5 MB, keeping two older files. On one Mac it had reached 33 MB.
- Less work while nothing is happening:
  - With the BarShelf Dock off, its window and the app-switch tracking behind it are no longer kept running in the background.
  - Desktop widgets are written to only while one is on the desktop, and an unchanged reading is not rewritten until it would read as old. This also saves macOS's daily widget-reload budget.
  - Where the menu bar cluster can't watch the pointer directly, it checks four times a second instead of thirty, and goes fast only near the menu bar.
