# BarShelf 0.3.6

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
