# R07 — First-run onboarding + gallery examples

## Problem (user feedback)
Packaged MenuBucket.app launches with cwd `/`, so `./widgets/` is never found
and a fresh install opened an **empty popup with no guidance**. The gallery
also lacked pointers to the user's own projects (Stashbar/file-stack, aas).

## Changes

### 1. First-run starter seeding
- **New** `Sources/MenubucketCore/StarterWidgetSeeder.swift` (Core → unit-testable):
  - Copies the CLI-free starters `hello` + `recent-files` from the app bundle
    (`MenuBucket.app/Contents/Resources/widgets/`, already populated by
    `scripts/build_app.sh`) into
    `~/Library/Application Support/menubucket/widgets/`.
  - One-time: marker file `~/Library/Application Support/menubucket/.seeded-v1`
    prevents re-seeding (deleting the starters keeps them gone).
  - Skips entirely when the dev dir `./widgets/` exists (dev mode unchanged, no
    marker) and when the user widget dir is already non-empty (marker only).
  - `aas-usage` / `otpeek` / `clock-script` are **not** seeded (need aas/otpeek
    CLI or Deno) — discovered via the gallery with a `requires` badge instead.
  - Missing bundled dir (plain `swift build` binary) → no-op **without**
    marker, so a later packaged launch can still seed.
- `WidgetRuntime.init` calls `seedStarterWidgets()` before `loadWidgets()`;
  on actual seeding it arms the welcome card via `prefs.markWelcomePending()`.

### 2. Onboarding / empty state (`RootView.swift`)
- `emptyState` replaced: "Time to tidy up your menu bar" + 3 CTAs —
  Open Widget Gallery (`GalleryWindowController.shared.show()`),
  Install Widget from URL (`WidgetInstaller.shared.promptForURL()`),
  Getting Started guide (`RootView.gettingStartedURL` →
  `https://github.com/jiunbae/menubucket/blob/master/docs/GETTING-STARTED.md`).
- **New** `WelcomeCardView`: one-time card rendered above the seeded `hello`
  widget ("Demo" page; falls back to the first page). Close button →
  `prefs.dismissWelcome()` (persisted). Card only ever appears when seeding
  actually copied widgets (existing users never see it).
- `WidgetPrefs`: new persisted `welcomePending` flag (`Persisted.welcomePending`
  is optional → backward compatible with pre-R07 `prefs.json`).

### 3. Gallery examples (`registry/index.json`)
- All 5 entries enriched; `install.url` now
  `https://github.com/jiunbae/menubucket/tree/master/widgets/<id>`; top-level
  `_comment` notes the repo is private → external installs won't work yet.
- `aas-usage`: homepage `https://github.com/Open330/aas`, description carries
  the aas install one-liner; `requires: "aas CLI"`.
- `otpeek`: homepage `https://github.com/jiunbae/otpeek`; `requires: "otpeek CLI"`.
- `recent-files`: Stashbar (file-stack) framing, homepage
  `https://github.com/jiunbae/file-stack`.
- `clock-script`: `requires: "Deno runtime"`; hello/clock tags & descriptions tidied.
- **New registry field `requires`** (free text, display-only):
  - `Registry.swift` `RegistryWidgetEntry.requires: String?` (+ init param)
  - `schema/registry-0.1.json` widgetEntry property (additive; additionalProperties
    was already true, so old consumers are unaffected)
  - `GalleryView.swift` GalleryCard shows an orange "Requires <X>" capsule badge.

### 4. Tests
- **New** `Tests/MenubucketCoreTests/StarterWidgetSeederTests.swift` (8 tests):
  seeds into empty dir / marker prevents reseed / dev dir disables (no marker) /
  missing dev dir still seeds / existing user dir untouched (marker written) /
  missing+nil bundled dir no-op without marker / file contents copied.
- `RegistryTests.testShippedSampleIndexParses` extended: asserts `requires` on
  aas-usage/otpeek/clock-script, nil on starters, and the file-stack/aas homepages.

## Verification
- `jq empty registry/index.json` + `schema/registry-0.1.json` — OK
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — OK
- `swift test` — **141/141 passed** (133 before + 8 new)

## Not touched (per constraints)
scripts/, docs/, README.md, sdk/; schema only got the allowed `requires` field.
No commits made.
