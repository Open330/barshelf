# R11 — W2-SETTINGS notes

Owner: Claude. File edited (only): `Sources/MenubucketApp/AppSettingsView.swift`.
Build: `swift build` passes (AppSettingsView.swift recompiles clean).

## What shipped

### 1. New "Widgets" tab (between General and Performance)
- Lists **all** widgets from `runtime.widgets` (sorted by effective bucket →
  override order → name). Disabled widgets are included even though they are
  absent from `runtime.pages` — confirmed `runtime.widgets` holds every loaded
  widget regardless of disabled state.
- Per row: SF-symbol icon (`manifest.icon`), name + id, enable switch
  (`runtime.setWidgetDisabled`), bucket `Menu` (options = `runtime.allGroups`
  ∪ current effective group, checkmark on current, plus "New Bucket…" →
  alert with TextField → `runtime.moveWidget`), up/down reorder chevrons,
  gear (`Settings…` → `WidgetSettingsView` sheet via `.sheet(item:)`),
  folder (Reveal in Finder → `NSWorkspace.activateFileViewerSelecting`),
  trash (`Remove…` → destructive confirmation alert → `runtime.removeWidget`;
  thrown errors surface in a second alert).
- Reorder: swaps the widget with its same-bucket neighbor and rewrites
  sequential `order` overrides for the whole group via
  `prefs.setOverride(group: existingOverrideGroup, order: Double(pos), …)`
  (preserves any group override, only rewrites order), then
  `runtime.objectWillChange.send()` so both the tab and pages recompute.
  Up disabled at group top, down at group bottom.
- a11y labels on every icon-only control; `.help` tooltips throughout.

### 2. Monitoring tab
- Prepended a colored status `Circle` (8pt) before the status text:
  green = OK, red = Failed, gray = No data. Text label retained (not
  color-only); dot marked `accessibilityHidden`.

### 3. General tab
- Added an "Open Popup Hotkey" section: `Toggle` bound to
  `popupHotkeyEnabled` + `TextField` bound to `popupHotkey`
  (disabled when the toggle is off) + caption "e.g. cmd+shift+b".
  Registration is W2-INSTALLER's job; this only writes prefs.

## ⚠️ BLOCKER for the hotkey feature — NOT my file to fix
`Sources/MenubucketApp/AppPrefs.swift` `update(_:)` reconstructs the
`AppPreferences` value with only 4 fields:

```swift
copy = AppPreferences(
    menuBarSymbol: copy.menuBarSymbol,
    refreshMultiplier: copy.refreshMultiplier,
    pauseWhenClosed: copy.pauseWhenClosed,
    launchAtLogin: copy.launchAtLogin)   // ← drops popupHotkeyEnabled + popupHotkey
```

Any edit to `popupHotkeyEnabled`/`popupHotkey` (mine, or W2-INSTALLER's
observer) is silently reset to defaults on the next `update()`. The two new
fields must be passed through here. This file is owned by neither W2-SETTINGS
nor listed under W1-FOUNDATION explicitly — integration/foundation must add the
two args to the reconstruction. My tab writes through the correct API and is
otherwise complete.
