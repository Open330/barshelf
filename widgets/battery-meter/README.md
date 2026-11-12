# Battery

A native battery card for BarShelf: a large percentage, a level-colored meter,
the charging state, the power source and the time left, read from one
`pmset -g batt` per refresh. It is a pure workflow widget, so it needs no Deno
and no extra tools.

## What it shows

- The charge as a big percentage and a meter.
- The state, in plain words: **Charging**, **Not charging** (plugged in but
  holding, as Optimized Battery Charging does), **Charged** or **On battery**.
- The power source (power adapter or battery), and the time left or the time
  until full when macOS has an estimate.
- A battery glyph and color that follow the level: green above 25%, orange
  above 10%, red below that.

On a Mac without a battery the card says **No battery** and the menu bar item
stays empty, rather than showing a red 0%.

## Menu bar and alert

Add it to the menu bar to see the percentage there, with a glyph that follows
the level. **Notify when the battery runs low** (off by default) sends one
notification when the Mac is on battery at or below **Low battery at or below
(%)**, 20% by default (BarShelf 0.7.21+).

## Permissions and refresh

The widget runs one fixed `/bin/sh -c` pipeline over `/usr/bin/pmset -g batt`;
it cannot run anything else. It refreshes when the popover opens, every minute
while it is visible and on wake, and checks in the background so the alert can
fire. Clicking the card opens Battery settings.
