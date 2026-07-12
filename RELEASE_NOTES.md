# BarShelf 0.1.2

This release makes external widgets first-class, improves the native widget
gallery, and prevents usage widgets from polling while their popup is closed.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **Popup-only refresh policy** — widgets can declare `popupOnly` so interval,
  wake/deadline, watcher, and event refresh paths remain dormant until the
  BarShelf popup is visible. This is especially useful for rate-limited usage
  APIs.
- **External widget ownership** — custom widgets install directly from their
  own repository URL, including GitHub `/tree/{branch}/{subdirectory}` links.
  Widget packages no longer need to be copied into the BarShelf registry.
- **Native aas Usage adapter** — additive support for the `aas usage --json`
  contract, rendered as compact Claude/Codex quota cards with reset times and
  vector provider marks. The widget package itself now lives in the
  [aas repository](https://github.com/Open330/aas/tree/main/widgets/barshelf-aas-usage).
- **Gallery and visual polish** — a shelved gallery layout, two-column usage
  meters, larger menu-bar mark, and refreshed light/dark product screenshots.
- **Native muxa rows** — muxa Watch uses compact two-line native rows instead
  of a terminal-style table.

## Install the aas widget

```bash
barshelf install https://github.com/Open330/aas/tree/main/widgets/barshelf-aas-usage
```

The older `mbk` executable remains available as a compatibility alias; new
commands and documentation use `barshelf`.

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.1.1...v0.1.2
