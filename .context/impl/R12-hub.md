# R12 — W1-HUB notes

Standalone "BarShelf" hub window with sidebar navigation; the former
standalone Gallery / Create / Settings windows are now sections of it.

## Files

- `Hub/HubWindowController.swift` (new) — `HubTab` enum (widgets/gallery/create/
  settings, `String` raw), `HubModel` (@Published tab), `HubWindowController`
  (`static let shared`, `show(runtime:tab:)`, `register(runtime:)`,
  `show(tab:)`). Single NSWindow 860×620, min 720×480, titled "BarShelf".
  `NSWindowDelegate.windowWillClose` restores `.accessory` (guarded: only if no
  other titled visible window remains); `show` sets `.regular` + activates.
- `Hub/HubView.swift` (new) — `NavigationSplitView` List sidebar bound to
  `HubModel.tab`; detail switches to HubWidgetsView / GalleryView / HubCreateView
  / AppSettingsView. Owns a `@StateObject GalleryModel` (reused, no refetch).
  Hidden ⌘, button jumps to Settings when hub is key. `HubCreateView` embeds
  `WidgetBuilderView` (a `@StateObject WidgetBuilderModel`); onCreated reloads
  widgets, onClose navigates back to Widgets.
- `Hub/HubWidgetsView.swift` (new) — moved + upgraded R11 Widgets tab. `List`
  with a `Section` per bucket and `.onMove` drag-reorder inside each bucket
  (rewrites dense `prefs.setOverride` order, preserves group). Enable toggle,
  bucket menu (+ New Bucket…), settings sheet, reveal, remove alert. Manual
  up/down chevrons dropped in favor of drag.

## Shims (signatures unchanged; RootView untouched)

- `AppSettingsWindowController.show(runtime:appPrefs:)` → hub `.settings`
  (appPrefs defaulted; RootView calls single-arg form).
- `GalleryWindowController.show()` → hub `.gallery` (uses registered runtime).
- `WidgetBuilderController.show(runtime:)` → hub `.create`.

## Entry points

- Status item context menu: "Open BarShelf…" added at top (→ hub `.widgets`),
  separator, then existing Refresh/Install/Gallery/Create/Settings items which
  now route into the hub via the shims. Popup footer buttons unchanged.
- `StatusItemController.init` calls `HubWindowController.shared.register(runtime:)`
  via `MainActor.assumeIsolated` (init is nonisolated, always main-thread) so the
  runtime-less `GalleryWindowController.show()` shim can open the hub.

## Settings

`AppSettingsView` is now settings-only (General / Performance / Monitoring)
behind a segmented sub-picker; the Widgets tab moved to HubWidgetsView.

## Build

`swift build` → Build complete. Only pre-existing WidgetRuntime Sendable
warnings; no errors in owned files. `main.swift` needed no change (activation
policy is managed by HubWindowController).
