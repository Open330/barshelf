# Clock

A native digital clock for BarShelf: a large 24-hour `HH:MM`, a live seconds
counter beside it, and the date underneath.

## What it shows

- Hours and minutes in 24-hour format, with tabular digits so the layout does
  not jump as numbers change.
- Seconds as a smaller counter.
- The weekday, month, and day, for example "Fri Sep 25".

## Permissions and refresh

The widget runs a single fixed `/bin/date` format string and nothing else, so
it has no external dependency and makes no network request. It refreshes every
second while the popover is visible and pauses when it is closed. Clicking the
card opens Date & Time settings, where you can change the system clock or time
zone the widget reads.
