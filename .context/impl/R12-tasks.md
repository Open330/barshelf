# R12 — Hub window, theming, popup redesign, triggers, agent-facing spec

Round 12 implements four directions from the 2026-07-09 follow-up review:
1. A standalone app window (hub) for settings / create / manage / gallery.
2. Agent-authored widgets: condensed machine-friendly spec of every widget API;
   widget theme/layout must be user- and author-adjustable.
3. Popup visual refresh (current design reads as rough).
4. More workflow sources and refresh triggers.

Multiple agents, **exclusive file ownership**, three waves. `swift build` may
wait on SwiftPM locks (fine). Tests run ONLY via
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-path .build-xctest`
(the default CLT toolchain has no XCTest; never point Xcode's toolchain at the
shared `.build`). Do NOT git add/commit.

## Shared contracts

### WidgetAppearance (W1-THEME, Core — consumed by W2-POPUP)
```swift
public struct WidgetAppearance: Codable, Equatable, Sendable {
    public enum Density: String, Codable, Sendable { case compact, regular }
    public enum CardStyle: String, Codable, Sendable { case plain, tinted }
    public var accent: String?        // SF color name ("blue"…"pink") or "#RRGGBB"
    public var density: Density?      // nil → .regular
    public var cardStyle: CardStyle?  // nil → .plain
    public var showHeader: Bool?      // nil → true
    public func merged(over base: WidgetAppearance) -> WidgetAppearance // self wins field-wise
}
// Manifest: public var appearance: WidgetAppearance?   (author defaults)
// WidgetPrefs: appearanceOverrides: [String: WidgetAppearance]
//   func appearanceOverride(for id: String) -> WidgetAppearance?
//   func setAppearanceOverride(_ a: WidgetAppearance?, for id: String)
//   func effectiveAppearance(for manifest: Manifest) -> WidgetAppearance
// Renderer: SwiftUI EnvironmentKey `\.widgetAppearance` (default WidgetAppearance())
//   + app-side helper: extension WidgetAppearance { var accentColor: Color? }
```

### Hub window (W1-HUB — consumed by everything after)
```swift
enum HubTab: String { case widgets, gallery, create, settings }
@MainActor final class HubWindowController {
    static let shared: HubWindowController
    func show(runtime: WidgetRuntime, tab: HubTab)
}
// Back-compat shims (keep signatures, RootView/others need no edits):
// AppSettingsWindowController.show(runtime:) → hub .settings
// GalleryWindowController.shared.show()      → hub .gallery
// WidgetBuilderController.shared.show(runtime:) → hub .create (or keeps its
//   own window if embedding is disproportionate — shim must still work)
```

### Triggers + http source (W2-TRIGGERS, Core)
```swift
public enum TriggerSpec: Equatable, Sendable {
    case wake              // NSWorkspace didWake
    case popupOpen         // every popup open (debounced ≥5s)
    case fs(path: String)  // directory/file change (DirectoryWatcher)
    case url               // barshelf://refresh?widget=<id>
}
// Manifest refresh block accepts: "triggers": ["wake", "popup-open", {"fs": "~/Downloads"}, "url"]
// Workflow source kind "http": {"kind":"http","url":"https://…","headers":{…}} —
// GET only, 20s timeout, 5MB cap, JSON body → same transform pipeline as exec.
// SECURITY: http requires manifest permission "network" (new PermissionKind);
// gated like exec via PermissionStore, shown in install-confirm + gallery chips.
```

---

## Wave 1 (parallel)

### W1-HUB — owner: Claude (opus)
**Files owned:** new `Sources/MenubucketApp/Hub/*.swift`, `StatusItemController.swift`, `AppSettingsView.swift`, `GalleryView.swift`, `Builder/WidgetBuilderWindow.swift`, `main.swift`

1. **Hub window**: one resizable NSWindow (~860×620, min 720×480) titled
   "BarShelf", sidebar navigation (SwiftUI `NavigationSplitView` or
   List-sidebar): **Widgets / Gallery / Create / Settings**. Implement the
   HubTab contract above. While the hub is open switch
   `NSApp.setActivationPolicy(.regular)` so it gets a Dock presence/cmd-tab;
   restore `.accessory` on close (guard: only if no other regular windows).
2. **Widgets section**: move the R11 "Widgets" management tab here and upgrade
   it — List with `.onMove` drag-reorder within a bucket (writes sequential
   order overrides via `prefs.setOverride`), bucket section headers, enable
   toggle, bucket menu, settings sheet, reveal, remove (reuse the R11 row
   logic; it currently lives in AppSettingsView.swift which you own — extract).
3. **Gallery section**: embed the existing `GalleryView` content (refactor the
   window-specific bits so the same SwiftUI view hosts in the hub; keep
   GalleryWindowController shim → hub).
4. **Create section**: host the Widget Builder flow. If embedding
   WidgetBuilderView is disproportionate, show a launcher pane (template
   blurb + "Open Builder" button) — but the sidebar item must exist and
   WidgetBuilderController shim keeps working.
5. **Settings section**: General / Performance / Monitoring as a segmented
   sub-picker inside the hub (AppSettingsView minus the Widgets tab).
   AppSettingsWindowController shim → hub .settings.
6. **Entry points**: status-item context menu gets "Open BarShelf…" (top,
   opens hub .widgets); existing Gallery/Create/Settings items now route to
   hub tabs via the shims. Popup footer buttons keep working unchanged
   (they call the shims — do not edit RootView).
7. Keyboard: ⌘, opens hub .settings when the hub is key. Esc does not close
   the hub (it's a real window).
8. Notes → `.context/impl/R12-hub.md`.

### W1-THEME — owner: Claude (opus)
**Files owned:** new `Sources/MenubucketCore/WidgetAppearance.swift`, `Sources/MenubucketCore/Manifest.swift`, `Sources/MenubucketApp/WidgetPrefs.swift`, `Sources/MenubucketApp/WidgetSettingsView.swift`, `Sources/MenubucketApp/Renderer/ViewTreeRenderer.swift`, `Tests/**` (theme tests)

1. Implement the WidgetAppearance contract exactly (Core stays UI-free; the
   `accentColor: Color?` helper lives app-side in the renderer file).
2. Manifest: optional `appearance` (lenient decode; invalid values → nil
   fields, never a decode failure).
3. WidgetPrefs: `appearanceOverrides` persisted in prefs.json
   (backward-compatible), the three API funcs. Effective = override merged
   over manifest default merged over neutral.
4. Renderer: `\.widgetAppearance` environment key; apply accent to the
   elements that currently hardcode `.accentColor`/default tints (progress,
   meter, badge, link) and density to renderer paddings/font sizes (compact ≈
   0.85× paddings, caption-size text where safe). Renderer must render
   identically to today when appearance is neutral.
5. WidgetSettingsView: new "Appearance" section (host-provided, shown for
   every widget below manifest settings): accent swatch row (system palette:
   default/blue/purple/pink/red/orange/yellow/green/gray + custom hex field),
   density picker, card style picker, Show header toggle, "Reset to widget
   default" button. Saving persists the override and refreshes the card.
6. Tests: appearance merge precedence, prefs round-trip + old-json decode,
   manifest lenient decode.
7. Notes → `.context/impl/R12-theme.md`.

---

## Wave 2 (after Wave 1 lands)

### W2-POPUP — owner: Claude (opus)
**Files owned:** `Sources/MenubucketApp/RootView.swift`, `Sources/MenubucketApp/PopupSurface.swift`, `Sources/MenubucketApp/ToastCenter.swift`

Visual refresh — the popup currently reads as rough. Goals, not pixel specs
(use judgment, stay native):
1. **Chrome**: header/footer on `.bar`-like material with hairline dividers;
   bucket title + page indicator feel like one composed toolbar, not stacked
   rows. Footer keeps R11's +/gear/chevrons/dots but tightened.
2. **Cards**: consume `\.widgetAppearance` + `prefs.effectiveAppearance` —
   tinted cardStyle = accent wash background; showHeader=false hides the card
   header row (refresh stays reachable via context menu); density=compact
   tightens card padding. Neutral look: softer border (0.12 opacity), subtle
   shadow, 10pt radius, consistent 12pt content insets, header typography
   `.caption` secondary → name reads quieter, content reads first.
3. **States**: nicer empty/loading (skeleton shimmer or ProgressView centered
   with caption), error banner styling consistent with toast capsule.
4. **Motion**: page-change spring stays; card highlight flash softened;
   hover on a card reveals the per-card refresh button (hidden at rest to
   reduce noise — a11y: still in the accessibility tree).
5. Popup stays 360×480; verify with the offscreen screenshot harness that
   light/dark both look right (`.build/debug/barshelf screenshot <dir>` —
   note it renders its own demo layout; also build a quick real-RootView
   check if the harness supports it, else rely on build+eyeball via code).
6. Notes → `.context/impl/R12-popup.md`.

### W2-TRIGGERS — owner: Claude (opus)
**Files owned:** `Sources/MenubucketCore/Workflow.swift`, `Sources/MenubucketCore/SchedulePolicy.swift`, `Sources/MenubucketCore/Manifest.swift`, `Sources/MenubucketCore/PermissionStore.swift` (network kind), `Sources/MenubucketApp/Scheduler.swift`, `Sources/MenubucketApp/WidgetRuntime.swift`, `Sources/MenubucketApp/WidgetInstaller.swift` (deep-link routing only), `Sources/MenubucketApp/DirectoryWatcher.swift`, `Tests/**` (trigger/http tests)

1. Implement the TriggerSpec contract: manifest `refresh.triggers` array
   (lenient decode), runtime registration per widget:
   wake (NSWorkspace.didWakeNotification), popup-open (runtime already
   observes popup visibility for pauseWhenClosed — debounce ≥5s per widget),
   fs (reuse DirectoryWatcher, tilde-expanded, coalesced 2s), url
   (`barshelf://refresh?widget=<id>` in the existing deep-link handler;
   unknown id → no-op; no widget param → refresh all).
2. Triggered refreshes respect the existing scheduler coalescing and do not
   double-fire alongside interval refresh (min spacing via SchedulePolicy).
3. **http workflow source** per contract: GET only, 20s timeout, 5MB cap,
   `Accept: application/json` default, response JSON feeds the existing
   transform pipeline. Requires new `network` permission: PermissionStore
   kind, manifest permissions decode, install-confirm summary line, gallery
   chip (chips render from permissions generically — verify, don't edit
   GalleryView). No redirects to non-https. Deny by default until approved
   like exec.
4. Tests: trigger decode (strings + objects mixed), http source behind
   permission (mock URLProtocol), debounce policy unit test.
5. Notes → `.context/impl/R12-triggers.md`.

---

## Wave 3 (after Wave 2)

### W3-SPEC — owner: Claude (opus)
**Files owned:** new `docs/AGENTS.md`, new `llms.txt`, `docs/WIDGET-SPEC.md` (append pointers only), `docs/MBK.md`, `README.md` (one link), mbk CLI sources (`Sources/MbkKit/**` or wherever the mbk commands live — locate first)

Audience: an LLM agent asked to "make me a widget". Deliverables:
1. **docs/AGENTS.md** — one self-contained file an agent can be handed:
   manifest schema (all fields incl. R11 `category`/`screenshot`, R12
   `appearance`, `refresh.triggers`, `network` permission), the three
   execution layers with a decision rule (exec vs workflow vs script), full
   UINode catalog with JSON examples per node, settings[] schema, permission
   model, install/test loop (`mbk validate`, `mbk install --local`, dev mode
   `./widgets/`), and 3 complete worked examples (one per layer). Accuracy
   over brevity, but no prose padding — an agent reads this once.
2. **llms.txt** at repo root pointing to AGENTS.md + key docs (llms.txt
   convention: short index with absolute GitHub URLs).
3. **`mbk agent-spec`** subcommand: prints AGENTS.md content to stdout
   (bundle the file as a resource or embed at build time — follow how mbk
   ships other resources; keep it working in dev checkout too). Update
   docs/MBK.md.
4. Cross-check every claim against the actual decoders (Manifest.swift,
   UINode.swift, Workflow.swift) — the spec must match code as of Wave 2.
5. Notes → `.context/impl/R12-spec.md`.

### W3-EXAMPLES — owner: Codex
**Files owned:** `widgets/**` (new example directories only), `registry/index.json` (append entries)

1. Two new example widgets showcasing R12: (a) a workflow widget using the
   `http` source + `network` permission + `wake` trigger (e.g. public JSON
   API like GitHub status or open-meteo temperature); (b) a workflow widget
   using an `fs` trigger + appearance defaults (e.g. Downloads folder watcher
   with tinted card).
2. Validate manifests against schema/ if a schema file exists; keep them
   CLI-free so they run everywhere.
3. Append registry entries with category/requires/permissions filled.
4. Notes → `.context/impl/R12-codex.md`.

---

## Integration (main agent, after each wave)
- Wave 1/2: `swift build` + full test run (Xcode toolchain, isolated path);
  fix cross-agent drift.
- Wave 3: validate example widgets load (dev mode discovery), registry JSON
  parses, `mbk agent-spec` runs.
- Screenshot harness after W2-POPUP; summary → `.context/impl/R12-summary.md`.
