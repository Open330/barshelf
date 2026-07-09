# R11 Summary — UX Overhaul (widget management, entry points, install polish)

Round 11 implemented all P0/P1/P2 items from the 2026-07-09 UX review via 7
parallel agents (4 Claude Opus, 1 Claude Sonnet, 1 Codex; Gemini CLI auth was
dead so its docs task fell to Sonnet). Exclusive file ownership per agent; two
waves (foundation → UI consumers).

## Shipped

### P0 — management UI
- **Card context menu** now: Pin / Settings / Refresh / Disable / Move to
  Bucket ▸ (incl. New Bucket…) / Reveal in Finder / Remove Widget… (confirm +
  error surfacing). (`RootView.swift`)
- **Popup footer entry points**: `+` menu (Gallery / Install from URL / Create
  Widget) and `⚙` (Settings) — management no longer right-click-only.
- **Settings ▸ Widgets tab**: full list incl. disabled; enable toggle, bucket
  picker, in-group reorder, per-widget settings sheet, Reveal, Remove.
  (`AppSettingsView.swift`)
- **Foundation**: `WidgetPrefs.disabled` / `bucketOverrides` (backward-
  compatible prefs.json), `WidgetRuntime.removeWidget` (path-traversal-safe) /
  `moveWidget` / `setWidgetDisabled` (descheduled; re-enable = immediate
  refresh) / `reveal(widgetID:)`, override-aware `pages`.

### P1 — install & onboarding
- Single-widget install success: no summary alert — popup opens and the new
  widget's card is revealed + highlighted (multi-install keeps summary, then
  opens popup). (`WidgetInstaller.swift`, `StatusItemController.swift`)
- `requires` is now actually probed on PATH (`RequirementChecker`, cached,
  off-main): gallery badge shows ready / not installed. Display-only.
- Builder "Run a command" has 6 template chips (gh / kubectl / df / brew /
  docker / git) that prefill command + suggested name/icon. (Codex)
- Welcome card gained a right-click/swipe tip line; GETTING-STARTED.md now
  introduces the Builder and a 위젯 관리 section; INSTALLING-WIDGETS.md covers
  Update flow + auto-open.

### P2 — polish
- Gallery: kind segmented filter + category chips (`category` field added to
  registry schema + index.json), Update button on newer registry version
  (semver-lenient compare), optional `screenshot` field rendered as card
  preview.
- URL installs show a non-modal progress panel (determinate when
  Content-Length known) with Cancel.
- Global popup hotkey (Carbon RegisterEventHotKey, default cmd+shift+b,
  off by default; General tab toggle + string field).
- Copy actions show a toast capsule (ToastCenter) instead of just beep;
  pinned-row overflow shows "+N pinned hidden"; Monitoring rows have a
  status dot alongside text.

## Verification
- `swift build` clean (CLT toolchain, shared `.build`).
- `swift test` under Xcode toolchain, isolated build path
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --build-path .build-xctest`): **185/185 pass** (incl. new
  MenubucketAppTests: prefs round-trip, old-json decode, page overrides,
  removeWidget traversal refusal).
- Offscreen screenshot harness (`barshelf screenshot <dir>`) renders
  popover light/dark + builder without regressions (note: it renders its own
  curated demo layout, not the live RootView footer).

## Integration fixes applied by the orchestrator
- `AppPrefs.update(_:)` reconstructed `AppPreferences` with only 4 fields,
  silently resetting `popupHotkeyEnabled`/`popupHotkey` on every update
  (found independently by W2-SETTINGS and W2-INSTALLER) — fixed by passing
  both fields through the validating init. (`AppPrefs.swift`)

## Known follow-ups
- `Package.swift` gained a `MenubucketAppTests` test target (foundation agent,
  append-only, required for app-layer tests).
- Manual smoke on a real session recommended: hotkey registration, download
  progress panel, Move to Bucket ▸ submenu, Settings ▸ Widgets reorder.
- Registry `screenshot` assets not generated yet (UI supports the field).
- Registry install URLs still point at the private repo (pre-publish blocker,
  unchanged this round).

Per-agent notes: R11-foundation.md, R11-gallery.md, R11-codex.md,
R11-gemini.md (docs, Sonnet fallback), R11-rootview.md, R11-settings.md,
R11-installer.md.
