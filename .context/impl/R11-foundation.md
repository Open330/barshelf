# R11 — W1-FOUNDATION implementation notes

Implements the shared API contract that Wave-2 agents code against. No contract
signature deviations.

## Files changed

### Sources/MenubucketApp/WidgetPrefs.swift
- New `struct BucketOverride: Codable, Equatable { var group: String?; var order: Double? }`.
- New published state: `disabled: Set<String>`, `bucketOverrides: [String: BucketOverride]`.
- API: `isDisabled`, `setDisabled`, `override(for:)`, `setOverride(group:order:for:)`
  (both-nil clears the entry), plus `removeAllState(for:)` (erases pins/settings/
  overrides/disabled in one save — used by `removeWidget`).
- `Persisted` gained optional `disabled: [String]?` and `bucketOverrides:` fields;
  `load` defaults them when absent (backward-compatible with pre-R11 prefs.json);
  `save` writes `disabled` as a sorted array and omits empty maps/sets.

### Sources/MenubucketApp/WidgetRuntime.swift
- `@Published var pendingReveal: String?` + `reveal(widgetID:)` (always publishes
  on the main thread).
- Page computation now override/disabled-aware: `effectiveGroup(for:)` (override
  group wins over manifest), private `effectiveOrder(for:)` (override order wins),
  and `pages` delegates to the pure static `computePages(_:group:order:isDisabled:)`
  — enabled widgets grouped, members sorted by effective order, pages ordered by
  their first member's order then group name. Empty groups disappear naturally.
  Kept side-effect free (no card republish storms).
- `allGroups` = distinct effective group names in page order; `bucketGroups` now
  delegates to `allGroups`.
- `removeWidget(id:) throws`: refuses unknown ids (`RuntimeError.widgetNotFound`)
  and directories outside the user widgets root (`RuntimeError.notRemovable`),
  guarded by the pure static `isRemovableWidgetDirectory(_:)` (standardizes `..`,
  requires a proper subdir of `userWidgetsRoot` — so dev-checkout `./widgets/` and
  path-traversal ids are refused). On success: deletes the dir, cancels any queued
  snapshot-cache write, removes the cached snapshot, `permissionStore.reset`,
  `prefs.removeAllState`, then `loadWidgets()` (rescan drops in-memory snapshot /
  card model / refresh stats / scheduler timers / script process).
- `moveWidget(id:toGroup:)`: writes a group override (empty → clears), preserves any
  existing order, republishes via `objectWillChange.send()`.
- `setWidgetDisabled(_:_:)`: updates prefs, reconfigures the scheduler with only
  enabled widgets, republishes pages; re-enabling triggers one immediate manual
  refresh.
- `widgetDirectory(for:)` returns the loaded widget's directory.
- Disabled widgets are never scheduled (`scheduler.configure` receives
  `loaded.filter { !prefs.isDisabled }` in `loadWidgets` and `setWidgetDisabled`)
  and never refreshed (early guard in `refresh(_:manual:)`).
- `RuntimeError` gained `widgetNotFound(String)` and `notRemovable(String)`.

### Sources/MenubucketApp/Scheduler.swift
- No change required. "Disabled widgets are never scheduled/refreshed" is satisfied
  entirely at the runtime layer (scheduler only ever receives enabled widgets;
  `refresh` guards disabled). Re-enable → `configure` + immediate refresh.

### Sources/MenubucketCore/AppPreferences.swift
- Added `popupHotkeyEnabled: Bool` (default false) and `popupHotkey: String`
  (default "cmd+shift+b", `defaultPopupHotkey`). Memberwise init + lenient
  `init(from:)` decode with `decodeIfPresent` defaults; blank hotkey snaps to the
  default. Backward-compatible with older app-prefs.json.

## Tests (all 16 pass)
- `Tests/MenubucketCoreTests/AppPreferencesTests.swift` (+2): hotkey round-trip;
  absent/blank hotkey → defaults.
- `Tests/MenubucketAppTests/WidgetPrefsTests.swift` (new): disabled + overrides
  round-trip, old-json decoding without new fields, both-nil clears override,
  `removeAllState` erases every trace (in-memory + persisted).
- `Tests/MenubucketAppTests/WidgetPagesTests.swift` (new): override regroup/reorder
  page ordering, disabled widget makes an empty group disappear.
- `Tests/MenubucketAppTests/WidgetRemovalGuardTests.swift` (new): path-traversal
  refusal (root itself, `../` escape, unrelated dir, dev-checkout; accepts a real
  child).

## Deviation from the file-ownership rule (unavoidable)
`MenubucketApp` is an `.executableTarget` with **no** test target, so the required
"override application in page computation" and "removeWidget path-traversal refusal"
tests could not compile anywhere. Added a single append-only `MenubucketAppTests`
`.testTarget` (deps: MenubucketApp, MenubucketCore) to `Package.swift`. This is the
only edit outside the four owned source files + `Tests/**`; it is non-conflicting
(no other Wave-1 agent touches Package.swift).

## Toolchain note for the integration agent
The default `swift` on PATH is Command Line Tools (Swift 6.2.4) which ships **no
XCTest** — `swift test` fails with "no such module 'XCTest'" for every target.
Run tests with the full Xcode toolchain and an isolated build path to avoid
polluting the shared `.build` (mixing 6.2.4 / 6.3.3 modules breaks incremental
builds):

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      swift test --build-path .build-xctest

`swift build` (CLT) is unaffected and passes.
