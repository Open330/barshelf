# R07 — aas repo: MenuBucket widget support

Date: 2026-07-08
Repo: /Users/jiun/workspace-open330/aas (Open330/aas, public)
Branch: `feat/menubucket-widget` (commit `22acdf5`) — **NOT pushed**; main session pushes/PRs after user confirmation.

## What was added

- `widgets/menubucket-aas-usage/widget.json`
  - Verbatim copy of `/Users/jiun/workspace/menubucket/widgets/aas-usage/widget.json`.
  - `id: dev.menubucket.aas-usage` kept as-is (install path / update identity is keyed on manifest.id).
  - exec widget: `aas usage --json`, `output: data`, `adapter: aas-usage`, discover chain `$AAS_BIN` → `~/.cargo/bin/aas` → homebrew → `/usr/local/bin` → PATH.
- `widgets/menubucket-aas-usage/README.md`
  - Intro, install (`mbk install https://github.com/Open330/aas`), deep link
    `menubucket://install?url=https%3A%2F%2Fgithub.com%2FOpen330%2Faas` + shields.io badge,
    screenshot placeholder (`docs/screenshot.png`, TODO comment), requirements, permissions
    summary, refresh behavior.
- `README.md` (aas main): new `## MenuBucket widget` section inserted between
  `## Commands` (usage-related content; main README had no aas-bar mention — aas-bar lives in
  `apps/aas-bar/README.md` + `docs/DESIGN-aas-bar.md`) and `## Status`. One-line install +
  link to https://github.com/jiunbae/menubucket and the widget dir. No existing content touched.

## Validation

- `jq empty widgets/menubucket-aas-usage/widget.json` → OK
- `/Users/jiun/workspace/menubucket/dist/mbk validate widgets/menubucket-aas-usage`
  → `valid: 1 widget(s) — .` (also re-run with absolute path, same result)

## Follow-ups

- Replace screenshot placeholder with a real capture at
  `widgets/menubucket-aas-usage/docs/screenshot.png`.
- Optional: registry entry PR (`registry/index.json`) once the widget URL install is live.
- If the widget manifest in menubucket (`widgets/aas-usage/`) changes, mirror it here —
  permission changes re-trigger the first-run approval card.
