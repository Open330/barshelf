# BarShelf 0.7.36

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Your settings survive a file BarShelf can't read. Widget preferences, permission decisions and app preferences are now read value by value, so one value written by a newer version no longer resets everything else. A file that can't be read at all is kept beside the new one (its name gets "corrupt" and the date), and BarShelf tells you. A settings change that can't be saved now says so instead of being lost quietly.
- The audit log (`~/Library/Logs/BarShelf/audit.log`) no longer grows without limit. Commands a widget runs on its own schedule are written once every 10 minutes with a count of the runs in between, and the file rotates at 5 MB, keeping two older files. On one Mac it had reached 33 MB.
