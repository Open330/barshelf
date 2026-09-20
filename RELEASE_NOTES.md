# BarShelf 0.2.1

You choose what the menu bar shows.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **The menu bar value is yours to pick.** 0.2.0 let you put a widget on the
  bar but not say what it showed — System was stuck on CPU, Sensors on CPU
  temperature. Both now expose settings:
  - **System** — show CPU, Memory or Disk, with or without a label
    (`29%` or `Mem 64%`).
  - **Sensors** — show CPU, GPU, Battery or the hottest sensor, in °C or °F.
    The unit applies to the widget card too, and Fahrenheit labels say `°F` so
    `123°F` is never misread as Celsius.
- **Two readings at once.** Settings are per widget *instance*, so duplicating
  System (Hub → Widgets → Duplicate) and pointing one copy at Memory puts both
  on the bar — the arrangement a dedicated system monitor gives you.
- **Reorder the shared strip.** Widgets sharing the BarShelf item are arranged
  with **Move Left / Move Right** in the widget's Settings → Menu Bar. (A
  widget with its own status item is dragged in the menu bar, as macOS
  already allows.) The ordering was stored but had no control behind it.

## For widget authors

An `enum` setting can now carry `optionTitles` — display labels parallel to
`options` — so a picker shows "Value only" instead of the stored `value`. A
mismatched length is ignored rather than mislabelling the choices.

`status.label` is evaluated in the same context as the view, so it can read
`settings.*`. Exposing a setting the label branches on is how a *user* gets to
choose what your widget shows in the menu bar — the two bundled widgets above
are worked examples. Branch with `if(eq(settings.key,'x'), …, …)` so an absent
or unknown value falls through to a sane default.

See [`docs/WORKFLOW.md`](https://github.com/Open330/barshelf/blob/main/docs/WORKFLOW.md).

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.2.0...v0.2.1
