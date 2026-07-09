# R12 — W2-TRIGGERS implementation notes

Scope: refresh triggers (`refresh.triggers`), `http` workflow source, new
`network` permission kind. Backward compatible — manifests without
`triggers`/`network` behave exactly as before.

## 1. TriggerSpec (Core: `Manifest.swift`)
- `public enum TriggerSpec: Equatable, Sendable { case wake, popupOpen, fs(path:), url }`.
- `refresh.triggers` decodes leniently: `Refresh` now has a custom
  `init(from:)`/`encode(to:)` that decodes the array as `[JSONValue]` and maps
  each entry through `TriggerSpec(json:)`, dropping anything unrecognized
  (unknown strings, non-string/object values, unknown object keys, empty fs
  path) without ever failing the decode. Absent key → `nil`.
- Accepted tokens: `"wake"`, `"popup-open"` (also `"popupOpen"`/`"open"`),
  `"url"`, and `{ "fs": "<path>" }`.

## Runtime registration (`Scheduler.swift`)
- `configure(widgets:)` calls `rebuildTriggers()`, which rebuilds the wake /
  popup-open id sets and per-widget `fs` `DirectoryWatcher`s (2 s coalesce).
  Because `configure` is called on removal (`removeWidget → loadWidgets`) and
  enable/disable (`setWidgetDisabled`), trigger state is cleaned up
  automatically for removed/disabled widgets; `lastAutoRefreshAt` is filtered
  to live ids and `triggerWatchers` cancelled in `deinit`.
- wake: existing `didWake` observer now also fires `wakeTriggerIDs` (spacing
  gated) after the stale-refresh batch.
- popup-open: `popupOpened()` fires `popupOpenTriggerIDs` with a ≥5 s per-widget
  debounce.
- fs: watcher fires → refresh when popup open (spacing gated), else queued in
  `pendingWatchEvents` and batched on next open (same path as `watchPaths`).
- url: routed by `WidgetRuntime.handleURLRefreshTrigger(widgetID:)` (see §URL).

## 2. Coalescing / min spacing (`SchedulePolicy.swift`)
- New pure API: `triggerAllowed(lastRefreshAt:now:minSpacing:)` +
  constants `popupOpenTriggerDebounceSec = 5`, `fsTriggerCoalesceSec = 2`,
  `triggerMinSpacingSec = 5`.
- Scheduler routes ALL automatic refreshes through `fireAutomatic(_:)` which
  records `lastAutoRefreshAt[id]`; triggered refreshes go through
  `fireTrigger(_:minSpacing:)` which checks `triggerAllowed` against that same
  reference — so a trigger never double-fires right after an interval refresh,
  and repeated popup opens fire at most once per 5 s. In-flight coalescing in
  `WidgetRuntime.refresh` remains the second layer of protection.

## 3. http workflow source + `network` permission
- `HttpSource` (Core, `Workflow.swift`): `fetch(_:session:)` — GET, **https
  only**, 20 s timeout, 5 MB streamed cap, default `Accept: application/json`
  (overridable), JSON body decoded to `JSONValue` → normal transform pipeline.
  A `RedirectGuard` task delegate blocks any redirect to a non-https URL.
  `session` is injectable for tests.
- `PermissionStore.PermissionKind { exec, network, keychain, notifications }` +
  `PermissionStore.manifestDeclares(_:in:)`.
- Manifest already carried `permissions.network: [String]?` (host allowlist).
- `WidgetRuntime.runWorkflowHTTPSource`: blocks unless (a) the manifest declares
  `network` AND (b) the URL host matches an allowlist entry
  (`WidgetRuntime.networkHostAllowed`: bare host, `*.suffix`, full-URL host, or
  `*`). Deny-until-approved is inherited from the existing whole-widget
  approval gate (`gatePermissions`, hash includes network). Blocks are audited
  (`network.blocked`); successful fetches audited (`network.fetch`).
- Install-confirm summary + CLI: added a `network:` line to
  `WidgetDiscovery.permissionSummary` (see DEVIATION).
- Gallery chips: verified NOT edited. See DEVIATION — network chip not shown.

## 4. Tests
- `Tests/MenubucketCoreTests/TriggerSpecTests.swift` — mixed decode, lenient
  drop, absent→nil, round-trip.
- `Tests/MenubucketCoreTests/HttpSourceTests.swift` — mock `URLProtocol`:
  success + Accept/GET, header override, non-https rejection (no request made),
  non-2xx, invalid JSON, `manifestDeclares(.network)`.
- `SchedulePolicyTests` — trigger debounce / min-spacing.
- `Tests/MenubucketAppTests/NetworkPermissionGateTests.swift` —
  `networkHostAllowed` allow/deny/wildcard/`*`, and `barshelf://refresh`
  deep-link routing to the hook.

## URL trigger + INTEGRATION HOOK REQUIRED
- `WidgetInstaller.handleDeepLink` now routes host `refresh`
  (`barshelf://refresh?widget=<id>`) to a new `onRefreshRequest:((String?)->Void)`
  hook; everything else still installs. No `widget` param / empty → `nil`.
- `WidgetRuntime.handleURLRefreshTrigger(widgetID:)` refreshes only widgets that
  declared a `url` trigger (unknown/non-opted-in id → no-op; nil → all
  url-trigger widgets).
- **Integrator must wire** (StatusItemController is not owned by this task —
  add near the other `WidgetInstaller.shared.on*` assignments, ~line 137):
  ```swift
  WidgetInstaller.shared.onRefreshRequest = { [weak self] widgetID in
      self?.runtime.handleURLRefreshTrigger(widgetID: widgetID)
  }
  ```
  `main.swift` already forwards all `barshelf://`/`menubucket://` URLs to
  `WidgetInstaller.shared.handleDeepLink`, so no `main.swift` change is needed.

## DEVIATIONS from strict file ownership
- Edited `Sources/MenubucketCore/WidgetDiscovery.permissionSummary` (not in the
  owned list) to add the `network:` summary line. The task said "WidgetInstaller
  builds that text" but that text is actually centralized in
  `WidgetDiscovery.permissionSummary` (used by the install-confirm dialog, the
  CLI, and HeadlessInstaller). Change is additive; WidgetDiscovery is unowned by
  any concurrent wave.
- Gallery chips: `GalleryView.permissionChipLabels` reads
  `RegistryWidgetEntry.PermissionsSummary` (Registry.swift), which has no
  `network` field, and renders exec/keychain/notifications explicitly (NOT
  generically). Per instructions I did not edit GalleryView or Registry.
  RESULT: a network permission does NOT currently render as a gallery chip.
  Making it appear needs `Registry.PermissionsSummary.network` + a chip in
  GalleryView — both owned elsewhere. Flagged for the integrator / W1-HUB owner.
