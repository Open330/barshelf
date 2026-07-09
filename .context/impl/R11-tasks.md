# R11 — UX Overhaul: widget management, entry points, install polish

Round 11 implements the P0/P1/P2 findings from the 2026-07-09 UX review.
Multiple agents work in parallel with **exclusive file ownership** — do not edit
files outside your assignment. All agents may `swift build` (SwiftPM locking
serializes concurrent builds; expect waits). Do NOT `git commit` or `git add`.

## Shared API contract (implemented by W1-FOUNDATION, consumed by Wave 2)

Wave-2 agents: code against these signatures; they will exist when you start.

### WidgetPrefs (Sources/MenubucketApp/WidgetPrefs.swift, persisted in prefs.json)
```swift
struct BucketOverride: Codable, Equatable { var group: String?; var order: Double? }
// stored (backward-compatible decoding: absent fields default to empty)
var disabled: Set<String>                      // widget ids hidden from popup & not refreshed
var bucketOverrides: [String: BucketOverride]  // widget id -> user override of manifest bucket
// API
func isDisabled(_ id: String) -> Bool
func setDisabled(_ id: String, _ flag: Bool)
func override(for id: String) -> BucketOverride?
func setOverride(group: String?, order: Double?, for id: String) // both nil clears entry
```

### WidgetRuntime (Sources/MenubucketApp/WidgetRuntime.swift)
```swift
// pages computation: apply bucketOverrides (group/order) over manifest values,
// exclude disabled widgets. Existing sort rules otherwise unchanged.
var allGroups: [String]                        // distinct effective group names, page order
func effectiveGroup(for id: String) -> String
func removeWidget(id: String) throws           // delete widget dir, clean snapshots/stats/prefs (pins, settings, overrides, disabled), rescan
func moveWidget(id: String, toGroup group: String)  // writes override, republishes pages
func setWidgetDisabled(_ id: String, _ flag: Bool)  // prefs + stop/start scheduling
func widgetDirectory(for id: String) -> URL?   // for "Reveal in Finder"
@Published var pendingReveal: String?          // widget id to jump-to + highlight
func reveal(widgetID: String)                  // sets pendingReveal on main thread
```

### AppPreferences (Sources/MenubucketCore/AppPreferences.swift)
```swift
var popupHotkeyEnabled: Bool   // default false
var popupHotkey: String        // default "cmd+shift+b"; format: lowercase modifiers+key joined by "+" (cmd, shift, opt, ctrl)
```

### ToastCenter (new, Sources/MenubucketApp/ToastCenter.swift — owned by W2-ROOTVIEW)
```swift
@MainActor final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var message: String?            // auto-clears after ~1.8s
    func show(_ message: String)
}
```

---

## Wave 1 (parallel)

### W1-FOUNDATION — owner: Claude (opus)
**Files owned:** `Sources/MenubucketApp/WidgetPrefs.swift`, `Sources/MenubucketApp/WidgetRuntime.swift`, `Sources/MenubucketApp/Scheduler.swift`, `Sources/MenubucketCore/AppPreferences.swift`, `Tests/**` (foundation tests only)

1. Implement the full shared API contract above.
2. `removeWidget` must be safe: only deletes directories under the user widgets
   root; refuses ids resolving elsewhere; cleans every per-widget state
   (snapshot, card model, refresh stats, pins, settings, overrides, disabled).
3. Scheduler: disabled widgets are never scheduled/refreshed; re-enabling
   resumes scheduling and triggers one immediate refresh.
4. `pages` respects overrides + disabled. Empty groups disappear. Keep the
   existing performance property (per-card models, no full republish storms).
5. AppPreferences: add the two hotkey fields (Codable-backward-compatible).
6. Tests: prefs round-trip with new fields, old-json decoding, override
   application in page computation, removeWidget path-traversal refusal.
7. Write implementation notes to `.context/impl/R11-foundation.md`.

### W1-GALLERY — owner: Claude (opus)
**Files owned:** `Sources/MenubucketApp/GalleryView.swift`, `Sources/MenubucketCore/Registry.swift`, new `Sources/MenubucketCore/RequirementChecker.swift`, `registry/index.json` (schema additions only)

1. **Kind filter + category chips**: segmented/chip row under the search field —
   All / exec / workflow / script, plus tag-derived category chips if tags exist.
   Add optional `category: String?` to registry entries (Registry.swift decode +
   index.json entries where obvious).
2. **Requires detection**: new `RequirementChecker` in Core — given a `requires`
   string (e.g. "aas CLI", "deno"), extract candidate binary names and check
   PATH (`/usr/bin/env which` via existing exec service or Process; cache
   results). Gallery card: if requirement missing, show the badge in orange
   with "not installed" state + tooltip; if present, green check style.
   Display-only for install (do not block installs).
3. **Update detection**: compare registry `version` to the installed widget's
   `widget.json` version (read from the installed directory). If newer →
   primary button becomes **Update**; same version → "Installed" + Reinstall
   (existing behavior); keep 2s poll but also re-check version.
4. **Screenshot field (stretch)**: accept optional `screenshot` (relative path/URL)
   in Registry entries and render a fixed-height preview image in the card when
   present (async load, graceful absence). Do NOT build a generation pipeline.
5. Write notes to `.context/impl/R11-gallery.md`.

### W1-BUILDER — owner: Codex
**Files owned:** `Sources/MenubucketApp/Builder/WidgetBuilderView.swift`, `Sources/MenubucketApp/Builder/WidgetBuilderModel.swift`

1. In the "Run a command" source step, add a **template picker**: 6 presets
   above the command field as small clickable chips that fill the command field
   (user can then edit + Test run):
   - GitHub Actions runs: `gh run list --limit 5 --json name,status,conclusion`
   - Kubernetes pods: `kubectl get pods -o json | jq '[.items[] | {name: .metadata.name, phase: .status.phase}]'`
   - Disk usage: `df -h / | tail -1 | awk '{print "{\"used\":\""$3"\",\"free\":\""$4"\",\"pct\":\""$5"\"}"}'`
   - Homebrew outdated: `brew outdated --json=v2 | jq '[.formulae[] | {name, current: .installed_versions[0], latest: .current_version}]'`
   - Docker containers: `docker ps --format '{{json .}}' | jq -s '[.[] | {name: .Names, status: .Status}]'`
   - Recent git commits: `git -C ~/your/repo log -5 --pretty=format:'{"hash":"%h","msg":"%s"}' | jq -s .`
2. Selecting a template also suggests a widget name + SF Symbol in step 3
   (prefill only if user hasn't typed one).
3. Keep layout clean: chips wrap in a FlowLayout-ish HStack/LazyVGrid; template
   selection is optional and never blocks the manual path.
4. Verify the target builds (`swift build`). Do not edit other files. Do not commit.
5. Write notes to `.context/impl/R11-codex.md`.

### W1-DOCS — owner: Gemini
**Files owned:** `docs/GETTING-STARTED.md`, `docs/INSTALLING-WIDGETS.md`

1. GETTING-STARTED.md: add a section (before the hand-written JSON tutorial)
   introducing the in-app **Widget Builder** (right-click menu → "Create
   Widget…", 3 steps: Source → Display → Details, Test-run button, no code
   needed). Keep the document's existing language/tone (Korean sections stay
   Korean).
2. GETTING-STARTED.md: add a short "위젯 관리" subsection: card right-click →
   Pin / Settings / Disable / Remove / Move to Bucket / Reveal in Finder;
   Settings window → Widgets tab for list management (these ship this round).
3. INSTALLING-WIDGETS.md: mention update flow (gallery shows Update when a
   newer version exists) and the popup auto-opening after install.
4. Do not change code. Write a summary of edits to `.context/impl/R11-gemini.md`.

---

## Wave 2 (starts after W1-FOUNDATION lands)

### W2-ROOTVIEW — owner: Claude (opus)
**Files owned:** `Sources/MenubucketApp/RootView.swift`, `Sources/MenubucketApp/ActionRouter.swift`, new `Sources/MenubucketApp/ToastCenter.swift`

1. **Card context menu**: add `Disable` (runtime.setWidgetDisabled), `Move to
   Bucket ▸` (submenu: runtime.allGroups + "New Bucket…" prompt →
   runtime.moveWidget), `Reveal in Finder` (widgetDirectory), and
   `Remove Widget…` (confirmation alert → runtime.removeWidget; errors → alert).
2. **Footer entry points**: left-align a `plus` button (menu: Widget Gallery…,
   Install from URL…, Create Widget…) and right-align a `gearshape` button
   (AppSettingsWindowController). Keep pager arrows/dots centered; adjust
   spacing so 360pt width still fits. Accessibility labels + .help on both.
3. **Reveal/highlight**: observe `runtime.pendingReveal` — jump pager to the
   widget's page, flash the card border (accent, ~1.5s fade), clear pendingReveal.
4. **Pinned overflow**: when pins > 2, show "+N more" caption linking… simply a
   small `Text("+\(n) pinned hidden")` button that opens the page of the next
   pinned widget. Minimal.
5. **Toast**: implement ToastCenter (contract above) + bottom-center capsule
   overlay in RootView (fade in/out). Replace `NSSound.beep()` in
   ActionRouter's copy handler with `ToastCenter.shared.show("Copied")`
   (keep beep as fallback if popup closed is fine — ToastCenter is popup-only).
6. **Welcome card coachmarks**: append one caption line to WelcomeCardView:
   "Tip: right-click the menu bar icon for Settings — swipe with two fingers to
   switch buckets."
7. Notes → `.context/impl/R11-rootview.md`.

### W2-SETTINGS — owner: Claude
**Files owned:** `Sources/MenubucketApp/AppSettingsView.swift`

1. **Widgets tab** (new, between General and Performance): list all widgets
   (including disabled ones — use runtime.widgets + prefs), each row: icon,
   name, effective bucket, enable toggle (setWidgetDisabled), bucket picker
   (allGroups + custom), order up/down buttons (setOverride order — swap with
   neighbor within group), "Settings…" button (opens WidgetSettingsView sheet),
   "Remove…" with confirmation (removeWidget), "Reveal in Finder".
2. **Monitoring polish**: prepend a colored status dot (green OK / red Failed /
   gray no-data) next to the status text — text stays (not color-only).
3. **General tab**: add "Open Popup Hotkey" row — Toggle bound to
   `popupHotkeyEnabled` + a TextField showing `popupHotkey` string with caption
   "e.g. cmd+shift+b" (W2-INSTALLER registers the actual hotkey; you only edit prefs).
4. Notes → `.context/impl/R11-settings.md`.

### W2-INSTALLER — owner: Claude
**Files owned:** `Sources/MenubucketApp/WidgetInstaller.swift`, `Sources/MenubucketApp/StatusItemController.swift`

1. **Post-install reveal**: after a successful install, skip the summary alert
   on single-widget success — instead open the popup (StatusItemController) and
   call `runtime.reveal(widgetID:)` for the new widget. Multi-widget installs
   keep the summary alert, then open popup.
2. **Download progress**: URL installs show a small non-modal progress panel
   (NSProgressIndicator, determinate when Content-Length known, else
   indeterminate) with a Cancel button; replaces silent wait.
3. **Global hotkey**: when `popupHotkeyEnabled`, register a Carbon/NSEvent
   global hotkey from `popupHotkey` (parse "cmd+shift+b" format; RegisterEventHotKey
   preferred — no accessibility permission). Toggling pref or changing the
   string re-registers (observe AppPrefs). Hotkey toggles the popup.
4. Notes → `.context/impl/R11-installer.md`.

---

## Integration (main agent, after all waves)
- `swift build && swift test`, fix conflicts/compile errors.
- Manual smoke via ScreenshotMode if applicable.
- Merge notes into `.context/impl/R11-summary.md`.
