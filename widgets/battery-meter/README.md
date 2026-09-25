# Battery

A native battery card for BarShelf: a large percentage, a level-colored meter,
and the charging state, read from `pmset`. It is a pure workflow widget, so it
needs no Deno and no extra tools.

## What it shows

- The charge as a big percentage and a meter.
- The state `pmset` reports: charging, discharging, or charged.
- A battery glyph and color that follow the level: green above 25%, orange
  above 10%, red below that.

On a Mac without a battery, `pmset` reports no percentage, so the card shows
0% and the state "unknown".

## Permissions and refresh

The widget runs one fixed `/bin/sh -c` pipeline over `/usr/bin/pmset -g batt`;
it cannot run anything else. It refreshes when the popover opens and every
minute while it is visible. Clicking the card opens Battery settings.
