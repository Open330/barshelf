# BarShelf 0.7.36

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Your settings survive a file BarShelf can't read. Widget preferences, permission decisions and app preferences are now read value by value, so one value written by a newer version no longer resets everything else. A file that can't be read at all is kept beside the new one (its name gets "corrupt" and the date), and BarShelf tells you. A settings change that can't be saved now says so instead of being lost quietly.
- The audit log (`~/Library/Logs/BarShelf/audit.log`) no longer grows without limit. Commands a widget runs on its own schedule are written once every 10 minutes with a count of the runs in between, and the file rotates at 5 MB, keeping two older files. On one Mac it had reached 33 MB.
- Less work while nothing is happening:
  - With the BarShelf Dock off, its window and the app-switch tracking behind it are no longer kept running in the background.
  - Desktop widgets are written to only while one is on the desktop, and an unchanged reading is not rewritten until it would read as old. This also saves macOS's daily widget-reload budget.
  - Where the menu bar cluster can't watch the pointer directly, it checks four times a second instead of thirty, and goes fast only near the menu bar.
- Settings ▸ Privacy now shows what you do not use at the top: a figure for installed widgets with no use, with the Usage on This Mac list right under it. While the counts are younger than 30 days it says "not used since" the day counting began instead of "in 30 days", and so does `barshelf usage`. In Korean, the line that names both a number of widgets and a number of days had the two swapped.
- The keyboard helper is harder to confuse and easier to get rid of. It no longer reopens BarShelf while you are logging out or shutting down, or when BarShelf is already open again; it stops by itself when the app has been deleted, or after fifteen minutes with no app. After a restart BarShelf no longer mistakes an unrelated process for an old helper. `barshelf dock restore-apple-dock` works when BarShelf has crashed and only the helper is left.
- Fixed several ways a widget refresh could collide with something else happening at the same moment (removing a widget, two folder-watching widgets finishing together, changing a widget's folder in Settings, an app update downloading). One of them could stop a widget's refresh timer after another widget was removed.
