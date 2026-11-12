# Calendar

A native month calendar for BarShelf: the month and year over a seven-column
grid, with today highlighted.

## What it shows

- The current month and year ("November 2026", "2026년 11월"), starting the
  week on Sunday.
- Every day of the month in a grid, with blank cells before the first day so
  dates line up under the right weekday.
- Today as a filled circle.

The grid is computed from BarShelf's clock; the widget runs no command. It
does not read your calendar events; for those, use the Next Meeting widget.

## Permissions and refresh

No permissions. It refreshes every hour and when your Mac wakes, so it moves
to the new day at midnight. Clicking it opens Calendar.
