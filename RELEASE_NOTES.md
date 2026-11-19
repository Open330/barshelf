# BarShelf 0.7.43

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- The chips in the menu bar are easier to read. Their icons were drawn upside down (a down arrow pointed up, the lightning bolt was mirrored); they are the right way up now. They are also larger, about 11 pt of drawing in the 18 pt disc instead of 7.5, and sit in the middle of the disc; before, some were a pixel off.
- Chips in the menu bar now sit side by side instead of overlapping, so every icon is whole and in the middle of its chip. Before, a chip covered half of the next one's icon. The cluster is wider for it (9 pt for each chip after the first); Settings ▸ Menu Bar ▸ Chips ▸ Spacing has the overlapping layout, where a covered chip's icon is drawn smaller in the part you can see.
- Simpler icons on the chips for the common readings (CPU, memory, power, temperature, battery, fan, disk, network, GPU, up and down): solid shapes that stay readable at this size. SF Symbols are still there under Chips ▸ Icons.
- Chip colours are a palette now: each chip keeps its widget's hue, and all of them are given the same lightness and strength, so a row reads as one set.
- New in Settings ▸ Menu Bar ▸ Chips, with a live preview: Style (Solid, Soft with a tinted disc and a coloured icon, Mono in the menu bar's own text colour), Colour strength (Vivid, Balanced, Muted), Icons, Icon size and Spacing.
