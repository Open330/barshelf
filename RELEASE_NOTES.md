# BarShelf 0.1.3

This release focuses on launch trust, safer third-party widgets, and
the first-run/authoring experience.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **Fail-closed permissions** — exec and workflow commands now require an exact
  allowlist match. File reads, thumbnails, drag items, and open/reveal actions
  are restricted to approved `readPaths`, including symlink-escape checks.
- **Clearer onboarding** — permission-free widgets open immediately; privileged
  widgets show file roots, network hosts, environment values, storage, and
  command access before approval.
- **Safer installs and updates** — remote installs require HTTPS, redirects stay
  on an approved origin, and widget updates are staged before the live package
  is replaced.
- **Keyboard and VoiceOver polish** — search fields keep their navigation keys,
  actionable containers use real buttons, and SDK accessibility label/hint/value
  metadata reaches the native renderer.
- **Authoring contract repair** — official schema URLs are publishable from the
  project site, SDK container/grid types match the renderer, and unsafe entry
  paths are rejected by validation and runtime.
- **Release gate** — public packaging now requires Developer ID signing,
  notarization, stapling, Gatekeeper assessment, and matching app/CLI versions.

`bsf` ships as the short alias; commands and documentation use the canonical
`barshelf` name.

**Full changelog:** https://github.com/Open330/barshelf/compare/v0.1.2...v0.1.3
