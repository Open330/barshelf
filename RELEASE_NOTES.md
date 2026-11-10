# BarShelf 0.7.17

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Keep Awake no longer starts a process to check its status. It used to run osascript every time the popup opened and once a minute while it stayed open; now it reads PowerDisplayGuard's two files directly. Turning it on, setting a time and stopping still go through its helper. (Keep Awake 0.2.0)
- Widgets cost less to refresh. Each `${…}` expression in a widget is now read once and kept, instead of being parsed again on every refresh, so the System and Sensors menu bar widgets compute their readings in about half the time. What every bundled widget shows is unchanged.
- Widget authors: a new workflow source, `fs.json`, reads one JSON file in `readPaths` without a subprocess. A missing or garbled file comes back as a reading (`exists`, `valid`) instead of an error. Also new: the `template` transform, which builds an object or reshapes a list, and the `date.ms`, `date.clock` and `duration.short` functions.
