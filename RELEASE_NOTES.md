# BarShelf 0.1.4

A small follow-up to 0.1.3: file-reading widgets you can point at a folder now
work wherever you point them, plus a new developer widget.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **User-picked folders now read correctly** — a widget that exposes a
  `directory` setting can be pointed at any folder without the read being
  blocked. Choosing the folder is treated as the grant, so it no longer has to
  be pre-declared in `permissions.readPaths`, and the "Showing cached data:
  file source path is not covered by permissions" fallback is gone. The pick is
  still symlink-canonicalized and cannot reach outside itself, and a manifest
  `default` cannot self-grant — only a folder you actually chose counts.
- **New — Codex Reset widget** — an unofficial forecast of a Codex quota reset
  in the next 48 hours, from willcodexquotareset.com: a 0-100 score tinted at
  the 70/40 marks, mirrored into the status item. Find it under the custom
  collection in the gallery.

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.1.3...v0.1.4
