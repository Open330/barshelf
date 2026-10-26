# Keep Awake

Keep the Mac awake for 1, 2 or 4 hours, or until a time you set — never
indefinitely — and see what else is keeping it awake.

Keep Awake doesn't change power settings itself. It asks
[PowerDisplayGuard](https://github.com/jiunbae/settings), the LaunchAgent that
owns the Mac's power policy, through two files in
`~/Library/Application Support/PowerDisplayGuard/`:

| File | Written by | What it says |
| --- | --- | --- |
| `status.json` | the guard, at least every 5 s | power source, phase (`ac`, `grace`, `battery`, `override`), the active request, and other processes holding sleep assertions |
| `override.json` | this widget | keep awake until a time, and whether to stay awake with the lid closed |

Requests are capped at 12 hours by both sides, so a forgotten session can't
block battery sleep for days. With the battery at 20 % or less the guard
ignores "stay awake with the lid closed", and the widget shows that.

## In the menu bar

Turn it on under BarShelf ▸ Menu Bar. The item shows the time left while a
request is active, the countdown to sleep just after unplugging, and a warning
when the guard stops answering (no status for more than 15 seconds).

## Settings

- **Stay awake with the lid closed** — applies to the next request.
- **“Until” time** — the time the “Until” button keeps it awake to.

## Permissions

It runs `/usr/bin/osascript` with its own `keep-awake.js` only (`status`,
`set`, `until`, `cancel`), and reads the guard's folder.
