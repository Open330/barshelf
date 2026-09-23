# BarShelf 0.3.7

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

- **Readings stop shoving each other around.** An item was exactly as wide as
  its current text, so a temperature going from 9° to 10° widened it and moved
  every item to its left. Items now reserve room for two digits by default —
  shorter numbers are padded with figure spaces, which are exactly one digit
  wide — so the ones digit stays put and the bar holds still. A reading that
  ever needs more (a 100%) widens its item once and it stays that wide.

- **Much more to set per item.** Each menu bar item now has:
  - **Width** — Steady (room for 1–6 digits), Fixed (a column of 32–120 pt), or
    Fit (the old behaviour).
  - **Text** — alignment of the label and value rows, size (S/M/L) and weight.
  - **Color** — the widget's own warning colors, monochrome, or a fixed tint.
  - **Update** — how often it refreshes while in the menu bar, from every
    second to every minute. A temperature does not need a CPU reading's two
    seconds, and slower is lighter on battery.

  Widgets can set defaults for all of it; your choices always win.

- **Two metric rows.** A new layout draws two readings in one item — upload
  and download, read and write — and the bundled **Network** widget uses it.

- **The stacked value fills the bar.** It was noticeably smaller than a system
  monitor's, and the reason was measurable: each row reserved its *line box*,
  which carries typographic leading and headroom above the capitals — about a
  quarter of the height, at these sizes, that the glyphs never use. Rows are
  now measured and placed by their ink (cap height plus descender), and the
  pair is scaled to fill whatever height the bar reports.

  On a 22-point bar the value goes from about 9pt to about 12pt. There is a
  ceiling, so a taller bar does not produce something that reads as another
  app's.

- **Clicking a menu bar reading opens that widget.** It used to open the whole
  shelf and scroll to the widget, which is a long way round from "what is this
  number?". A status item that shows one widget's value now answers for that
  widget: its card hangs off that item, sized to the card rather than to the
  shelf, and clicking the item again closes it. Right-click still gives the
  item's own menu.

- **Heavier type, and no decimal place.** At menu bar sizes a regular weight
  reads thin against the bar's own chrome, so both rows are semibold and the
  shared strip is a touch heavier than menu text. Menu bar readings are whole
  numbers now — a decimal in a 12-point slot buys nothing and costs width.
  The card still shows the precise figure.

## Efficiency

BarShelf sits in the menu bar all day, so what a reading costs while nobody is
looking at it is what the app costs. On the three-item setup it was built
around (CPU, RAM, temperature), **CPU use is down from about 2.9% of a core to
about 0.8%**, measured the same way before and after:

- The Sensors widget reads only the sensor its menu bar item shows while its
  card is closed — 18 of the 129 temperature keys on an M-series laptop,
  instead of all of them — and everything again when you open it.
- Menu bar items are only redrawn when what they show changes, and only that
  item; a tooltip changing is no longer a reason to repaint.
- Items keep a fixed length while their width holds, so macOS stops
  re-measuring them on every update.
- Workflow files, expression parsing and the render cache are no longer redone
  or rewritten on every refresh; timers of items with the same interval wake
  the app together.

## Widgets update with the app

- **A widget fix now reaches you.** A widget's behaviour lives in its files,
  and until now an app update never replaced a widget you already had — so
  fixes shipped and changed nothing until you reinstalled by hand. BarShelf now
  updates installed bundled widgets when the app carries a newer version. It
  never reinstalls one you removed, and it leaves a widget you edited yourself
  alone.

## Fixes

- **A script widget exiting could take BarShelf down with it.** Sending a
  refresh to a widget whose process had just exited raised a signal that
  terminated the whole app. It now fails that one refresh instead.

## Settings

- **The menu bar settings were a pile.** They had grown a control at a time
  without anyone standing back: two unlabelled radio groups in a row, so four
  buttons with nothing saying which question either pair answered; the icon
  field and the checkbox governing it separated by another control; and one
  paragraph of help covering three unrelated things.

  Each row now states its question — Item, Layout, Label, Icon — with its hint
  underneath it, and a **live preview** shows the item as the menu bar will
  actually draw it, using the menu bar's own renderer so it cannot drift into
  describing something else.

- **One control per decision.** The System widget carried its own "Value only /
  With label" setting, which did the same job as the Label field a layer above
  it — turn both on and the bar read `CPU CPU 23%`. The widget-specific one is
  gone; the Label field works for every widget and can now be switched off, so
  "just the number" is still sayable.
