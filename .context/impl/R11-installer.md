# R11 — W2-INSTALLER notes

Owner: Claude. Files edited (only these two):
- `Sources/MenubucketApp/WidgetInstaller.swift`
- `Sources/MenubucketApp/StatusItemController.swift`

Build: `swift build` clean, no warnings. (Did not run `swift test`.)

## 1. Post-install reveal
`WidgetInstaller` gained two callbacks alongside `onInstalled`:
- `onOpenPopup: (() -> Void)?`
- `onReveal: ((String) -> Void)?`

`processDiscovery` now tracks `installedIDs` and, after `onInstalled?()`:
- **Clean single-widget install** (`installedIDs.count == 1 && failed.isEmpty`):
  skips the summary alert, calls `onReveal?(id)`.
- **Everything else** (multi-widget, or partial failure): keeps `showSummary`,
  then `onOpenPopup?()` when at least one widget installed.

This covers both the URL path and the bundled/registry path (both funnel
through `processDiscovery`).

`StatusItemController.init` wires:
- `onOpenPopup` → `openPopupIfNeeded()` (shows popup only if hidden).
- `onReveal` → `openPopupIfNeeded()` then `runtime.reveal(widgetID:)`.
Order: popup opened first, then `pendingReveal` set — the popover's hosting
controller exists from init, so RootView is subscribed even while hidden.

## 2. Download progress panel
New `DownloadProgressPanel` (in WidgetInstaller.swift): small non-modal
floating `NSPanel` (`.titled, .utilityWindow`, `isFloatingPanel`) with an
`NSProgressIndicator` (bar) + Cancel button.
- Determinate when Content-Length > 0 (shows `x.x MB / y.y MB`), else
  indeterminate spinner. Starts indeterminate until the first byte report.
- Marked `@unchecked Sendable` (main-thread-only) so the progress callback can
  capture it across the download's concurrency domain.

New `WidgetInstallFlow.prepare(input:progress:)` + `download(from:progress:)`
mirror `HeadlessInstaller.fetchSession` (download → extract → discover, with
the HTTP-404 and subdirectory-not-found candidate fallbacks) but stream byte
counts and honor `Task` cancellation (`Task.checkCancellation()` in the byte
loop, reported every 64 KB). Uses public Core APIs: `WidgetInstallSource.parse`,
`SafeZipExtractor.extract`, `WidgetDiscovery.discover`. Non-remote inputs
(local dir/archive paths, unparseable) fall back to the plain
`prepare(input:)` pipeline. Same 128 MB cap (`WidgetInstallFlow.maxDownloadBytes`).

`install(input:)` shows the panel, drives the progress download, and wires
`panel.onCancel = { task.cancel() }`. `CancellationError` closes the panel
silently; other errors close it then `showError`. Only URL installs get the
panel; bundled installs (`installBundledWidget`) do not.

## 3. Global hotkey (Carbon)
`import Carbon.HIToolbox` in StatusItemController.
- `updateHotkey(_ preferences:)` runs on every `appPrefs.$preferences` change
  (added to the existing sink) and once at init. It unregisters, then (if
  `popupHotkeyEnabled` and the string parses) registers.
- `RegisterEventHotKey` via a single app-wide `kEventHotKeyPressed` handler
  (installed once, `Unmanaged` self pointer in userData; forwards to
  `hotkeyPressed()` → `togglePopup()` on main). No accessibility permission.
- `parseHotkey`: lowercase modifiers (cmd/command, shift, opt/option/alt,
  ctrl/control) + exactly one final key joined by "+". Requires ≥1 modifier
  and a known key (a–z, 0–9, space/return/tab). Anything unrecognized →
  `nil` → no hotkey (fail silently, no crash).
- deinit unregisters the hotkey and removes the event handler.

## ⚠️ Blocker for integration (outside my file ownership)
`Sources/MenubucketApp/AppPrefs.swift` `update(_:)` reconstructs
`AppPreferences` with only 4 fields:
```swift
copy = AppPreferences(
    menuBarSymbol: ..., refreshMultiplier: ...,
    pauseWhenClosed: ..., launchAtLogin: ...)
```
This **drops `popupHotkeyEnabled` and `popupHotkey`** (they revert to init
defaults). So toggling the hotkey through Settings (W2-SETTINGS) will never
persist — the hotkey feature is inert end-to-end until `update` is fixed to
pass those two fields through. AppPrefs.swift is not in my ownership; the
integration agent (or whoever owns AppPrefs.swift) must add:
`popupHotkeyEnabled: copy.popupHotkeyEnabled, popupHotkey: copy.popupHotkey`.
My registration code is correct and re-registers on prefs changes; it just
never receives a changed value while this defect stands.
