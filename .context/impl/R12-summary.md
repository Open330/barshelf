# R12 Summary — Hub window, theming, popup redesign, triggers, agent spec

Round 12 implemented the four 2026-07-09 follow-up directions plus the SDK
bundling bug, via 5 Claude Opus agents + 1 Codex agent in three waves
(exclusive file ownership, same working tree).

## Shipped

### 1. Hub window (W1-HUB)
- Standalone "BarShelf" window (860×620) with sidebar: **Widgets / Gallery /
  Create / Settings** (`Sources/MenubucketApp/Hub/`).
- Widgets section: R11 management list moved here + `.onMove` drag-reorder
  within buckets; Gallery and Builder embedded; Settings = General/
  Performance/Monitoring sub-picker.
- Legacy AppSettingsWindowController / GalleryWindowController /
  WidgetBuilderController are shims routing to hub tabs (RootView untouched).
- "Open BarShelf…" added to the status menu; activation policy flips to
  `.regular` while the hub is open, back to `.accessory` on close; ⌘, → Settings.

### 2. Theming / layout (W1-THEME)
- `WidgetAppearance` (Core): accent (SF name or #RRGGBB), density
  (compact/regular), cardStyle (plain/tinted), showHeader; field-wise
  `merged(over:)`; lenient decode.
- Manifest `appearance` author defaults; `WidgetPrefs.appearanceOverrides`
  user overrides; effective = override ▸ author ▸ neutral.
- Renderer `\.widgetAppearance` env key applies accent + density inside the
  tree (neutral renders pixel-identical to before).
- WidgetSettingsView "Appearance" section for every widget (swatches + hex,
  density, card style, show header, reset).

### 3. Popup redesign (W2-POPUP)
- Header/footer on `.bar` material; header composes bucket title + "n of m".
- Cards: appearance consumption (tinted wash, hidden header, compact
  padding), softer neutral look (0.12 border, 10pt radius, subtle shadow,
  quiet caption headers), hover-revealed per-card refresh (kept in a11y
  tree), centered loading state, toast-consistent error banners.

### 4. Triggers + http source (W2-TRIGGERS)
- `refresh.triggers`: `wake` / `popup-open` (≥5s debounce per widget) /
  `{"fs": path}` (2s coalesce) / `url` (`barshelf://refresh?widget=<id>`,
  no param = refresh all). Lenient decode; cleanup on remove/disable.
- Trigger fires respect SchedulePolicy min-spacing vs interval refresh.
- Workflow `http` source: GET, https-only (redirect downgrade blocked), 20s
  timeout, 5MB cap; gated behind new `network` permission (PermissionStore
  kind + manifest decode + host allowlist incl. `*.suffix`), audited.

### 5. Agent-facing spec (W3-SPEC)
- `docs/AGENTS.md`: self-contained authoring spec (manifest schema, layer
  decision rule, 13-node UINode catalog with JSON examples, actions,
  settings[], appearance, permissions, triggers, mbk test loop, 3 worked
  examples). `llms.txt` at repo root.
- `mbk agent-spec` prints it (on-disk lookup with executable walk-up +
  compiled-in fallback via `scripts/gen-agent-spec.py`).

### 6. Example widgets (W3-EXAMPLES, Codex)
- `widgets/github-status/` (http source + network permission + wake trigger)
  and `widgets/downloads-watch/` (fs trigger + tinted appearance); both
  `mbk validate` clean; registry entries appended with category/permissions
  (registry summary + gallery chip now include `network`).

### 7. SDK not-found bug (orchestrator)
- Root cause: `build_app.sh` never bundled `sdk/` → packaged apps failed all
  script widgets with "BarShelf SDK (sdk/mod.ts) not found".
- Fixed: build script copies `sdk/` into Resources; `locateSDKModule()` gains
  executable-relative walk-up (works from any cwd in dev); error message now
  says how to fix.

## Integration fixes (orchestrator)
- Wired `WidgetInstaller.onRefreshRequest` → `runtime.handleURLRefreshTrigger`
  in StatusItemController.
- Added `network` to `Registry.PermissionsSummary` + gallery chip.
- `testShippedSampleIndexParses` count 5 → 7 (Codex's two entries).
- Lint fix in `gen-agent-spec.py`.

## Verification
- `swift build` clean; **220/220 tests pass** (Xcode toolchain,
  `--build-path .build-xctest`).
- `mbk agent-spec` verified (repo cwd, walk-up, isolated copy);
  `mbk validate` passes both new widgets.
- Screenshot harness renders light/dark popover + builder without crashes
  (harness uses its own demo chrome; new popup chrome verified by build +
  code review only).

## Known follow-ups
- Manual smoke recommended: hub window activation-policy dance, drag-reorder,
  appearance editing end-to-end, http widget approval flow, wake/fs triggers.
- Screenshot harness could adopt the real RootView chrome so popup redesigns
  are visually regression-tested.
- Registry `screenshot` assets still not generated.

Per-agent notes: R12-hub.md, R12-theme.md, R12-popup.md, R12-triggers.md,
R12-spec.md, R12-codex.md.
