# Clock

A native digital clock for BarShelf: a large `HH:MM` and the date underneath,
in the app's language.

## What it shows

- Hours and minutes, 24-hour by default or 12-hour with AM/PM (**Hour format**
  in the widget's settings), with tabular digits so the layout does not jump.
- The weekday, month and day, for example "Thursday, November 12" or
  "11월 12일 목요일".

## Permissions and refresh

The widget runs no command and makes no network request: the time comes from
BarShelf's own clock. It refreshes every 10 seconds, on the 10-second mark, so
the minute changes on time, and when your Mac wakes. Clicking the card opens
Date & Time settings, where you can change the system clock or time zone.
