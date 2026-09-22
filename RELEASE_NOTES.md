# BarShelf 0.3.7

> Unreleased. Requires macOS 13+ on Apple Silicon.

## Menu bar

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
