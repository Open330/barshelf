# R11 — W1-GALLERY implementation notes

Scope: gallery filters, requires-CLI detection, update detection, optional
screenshot preview. Files owned & edited:
- `Sources/MenubucketApp/GalleryView.swift`
- `Sources/MenubucketCore/Registry.swift`
- `Sources/MenubucketCore/RequirementChecker.swift` (new)
- `registry/index.json` (schema/field additions only)

## 1. Kind filter + category chips
- New `GalleryKindFilter` enum (`all/exec/workflow/script`) rendered as a
  segmented `Picker` under the search field.
- Category chips = per-entry `category` field ∪ `tags`, de-duplicated
  case-insensitively and sorted; rendered as a horizontally-scrolling capsule
  row with an "All" chip. Chips recompute against the current kind segment;
  `.onChange(of: kindFilter)` clears a now-invalid category selection.
- `filteredEntries` composes three predicates: kind, category, search
  (name/tag substring). Empty-state copy distinguishes "registry empty" from
  "filters excluded everything".
- Registry: added optional `category: String?` to `RegistryWidgetEntry`
  (decode + init). index.json entries tagged: Demo / Files / Developer /
  Security.

## 2. Requires detection (RequirementChecker, Core)
- `RequirementChecker.shared` maps a free-text `requires` string to
  `Status {satisfied, missing, unknown}`.
- `candidateBinaries(from:)`: strips parenthetical noise + noise words
  (CLI/runtime/tool/…), takes the leading meaningful token, offers verbatim +
  lowercased spellings. e.g. "aas CLI"→["aas"], "Deno runtime"→["Deno","deno"].
- PATH resolution is pure `FileManager` stat over env `PATH` +
  `ExecService.fallbackPathDirectories` (no `Process`, no shell). Every binary
  result is memoized under an `NSLock`; `invalidateCache()` resets.
- Never blocks the main thread: `GalleryModel.recomputeRequirements()` runs a
  detached `.utility` task after each registry load and publishes the id→status
  map back on `MainActor`. Card reads the cached status only.
- Card badge: green `checkmark.seal` "ready" when satisfied, orange
  `exclamationmark.triangle` "not installed" when missing, neutral
  `wrench.and.screwdriver` "Requires X" while pending/unknown. Display-only —
  installs are never blocked. Accessibility labels + `.help` on all states.

## 3. Update detection
- `SemanticVersionOrder` (Registry.swift): lenient dotted-number compare
  (numeric components numerically, else string; numeric outranks pre-release
  text). `isNewer(candidate, than:)` guards nil.
- `GalleryModel.refreshInstalledStates()` now also reads each installed
  widget's `~/…/widgets/<id>/widget.json` top-level `version` (via a private
  `VersionProbe`, matching WidgetDiscovery) into `installedVersions`.
- `updateAvailable(for:)` = installed AND registry version strictly newer.
  Card primary button becomes **Update** (accent, default action) with an
  "Update available" label; otherwise existing Installed+Reinstall / Install.
- The existing 2s `installedPoll` calls `refreshInstalledStates`, so version
  re-checks happen on the same cadence as install-state re-checks.

## 4. Screenshot field (stretch)
- Registry: optional `screenshot: String?` (http(s)/file URL). index.json
  documents it but ships none.
- Card renders a fixed-height (120pt) `AsyncImage` preview above the row when
  the value forms an http(s)/file URL: placeholder while loading, `EmptyView`
  on failure or bare relative paths (graceful absence). No generation pipeline.

## Build / coordination notes
- `swift build` briefly failed at manifest planning because W1-FOUNDATION added
  a `MenubucketAppTests` target to Package.swift before its sources existed
  (concurrent). Verified my four files compile by adding a temporary placeholder
  test, building green, then removing it — W1-FOUNDATION's real
  `Tests/MenubucketAppTests/WidgetPagesTests.swift` had landed by then and was
  left untouched.
- Final: MenubucketApp + MenubucketCore compile clean (`Build complete!`).
- No git add/commit performed.
