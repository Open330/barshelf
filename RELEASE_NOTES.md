# BarShelf 0.3.4

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Menu bar API

- **A widget can now name its own icon and colour, per refresh.** Both were
  manifest-only, which meant neither could follow a value — a battery icon
  could not track its level, and a reading could not go red when it mattered.
  `status.icon` takes an SF Symbol name and `status.tint` one of `accent`,
  `good`, `warning`, `danger`, `secondary` — the same words the view layer
  uses, so a widget says `danger` in one vocabulary rather than two. Script
  widgets get both through `host.render`'s status.

  Leave the tint off unless the colour carries meaning: without one the item is
  a template image, which follows a light or dark menu bar and inverts while
  held open, and a fixed colour trades both away. An unknown name loses the
  colour, not the reading.

  The bundled **System** and **Sensors** widgets use it — their menu bar
  readings turn orange past 75% and red past 90%, matching the thresholds their
  cards already drew.

## The menu bar actually keeps up now

Two things were stopping a promoted widget from staying current, and between
them a live reading could sit unchanged for as long as the app was left alone.

- **The battery saver paused it.** "Pause when closed" is about work nobody can
  see, and a widget in the menu bar is the one thing that is always visible.
  Promoted widgets are now exempt; everything else still pauses, and taking a
  widget out of the menu bar still stops it.
- **App Nap throttled the whole app.** An accessory app with no windows is
  exactly what App Nap is for, and it took this one: the process ran at low
  priority and a two-second timer fired about once every eight seconds.
  BarShelf now holds that off — but only while something is drawn in the menu
  bar, so an empty menu bar naps like any other app.

Measured with the battery saver left on: idle `19%` with no colour, then `99%`
in red under load, then `4%` again.
