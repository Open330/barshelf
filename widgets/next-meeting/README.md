# Next Meeting

See the next event from macOS Calendar without opening the app. The widget shows
the event title, its calendar, time, time remaining, and location. When Calendar
contains a Zoom, Google Meet, Teams, Webex, or other HTTP(S) URL, a **Join**
button appears automatically.

## Setup

1. Add the widget and approve its single declared command:
   `/usr/bin/osascript -l JavaScript ./calendar.js <days> <all-day>`.
2. On the first refresh, macOS may ask for Calendar automation access. Approve
   it in **System Settings → Privacy & Security → Automation**.
3. Use widget settings to choose a 1–30 day search window and whether all-day
   events should be included.

Event output is marked sensitive. BarShelf receives only the nearest matching
event and persists a redacted fallback instead of the title or location.

## Files

- `widget.json` declares the script runtime, refresh behavior, settings, and the
  exact `osascript` allowlist shape.
- `calendar.js` is a local JXA query executed by macOS `osascript`.
- `index.ts` formats the result and renders native BarShelf nodes.
