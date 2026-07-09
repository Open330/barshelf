# R12 W3-SPEC — agent-facing widget spec

Deliverables (all done, `swift build` clean, `mbk agent-spec` verified).

## Files
- `docs/AGENTS.md` (new) — self-contained widget-authoring spec for LLM agents.
- `llms.txt` (new, repo root) — llms.txt-convention index with absolute
  `https://github.com/Open330/barshelf/blob/master/...` URLs.
- `Sources/MbkCLI/MbkKit/AgentSpec.swift` (new) — `AgentSpec.render()` +
  `locate()` (cwd → `#filePath` repo-relative → executable walk-up → embedded).
- `Sources/MbkCLI/MbkKit/AgentSpecEmbedded.swift` (new, generated) — embedded
  copy of AGENTS.md as a `#####"""…"""#####` raw string.
- `scripts/gen-agent-spec.py` (new) — regenerates the embedded file from the doc.
- `Sources/MbkCLI/MbkKit/MbkMain.swift` — added `agent-spec` case + usage line.
- `docs/MBK.md`, `README.md` (docs table row), `docs/WIDGET-SPEC.md` (pointer)
  updated.

## Design decisions
- **Embed, not bundle.** The release tarball (`scripts/release.sh`) ships only
  the bare `mbk` binary — no `.app`, no resources, no docs. So a SwiftPM
  resource / `Bundle.module` would fail in the packaged case (and release.sh
  isn't ours to edit). `agent-spec` prefers the on-disk `docs/AGENTS.md` (dev
  checkout stays live) and falls back to the compiled-in copy. Verified: from a
  repo cwd, via executable walk-up, and truly isolated (binary copied to /tmp)
  all print identical 21980-byte output.
- Raw-string delimiter is `#####` so backticks / `${...}` / `"""` in the doc are
  literal; closing delimiter at column 0 (leading-whitespace stripping rule).

## Ground-truth cross-checks (code as of Wave 2)
- Manifest fields per `Manifest.swift`: entry.kind exec|script|workflow|builtin;
  source.output viewtree|data; refresh.interval null=no poll; refresh.triggers
  lenient (`wake`, `popup-open`/`popupOpen`/`open`, `url`, `{fs:path}`);
  appearance lenient (accent SF-name|#RRGGBB, density compact|regular, cardStyle
  plain|tinted, showHeader).
- **`category`/`screenshot` are Registry entry fields (`Registry.swift`), NOT
  manifest fields.** Documented under §11 as registry-only to avoid a wrong
  claim (the task brief conflated them with the manifest).
- UINode: renderer (`ViewTreeRenderer.swift`) switches on `UINode.KnownType` —
  exactly 13 types render; SDK's `zstack`/`scroll`/`none` fall through to the
  unsupported placeholder. Documented the 13 authoritatively.
- NodeAction types from `UINode.swift`: copyText, openURL, openFile, revealFile,
  refresh, run, event.
- Workflow `use` from `WidgetRuntime.swift`: exec, fs.directory, http. http
  source (`Workflow.swift`): https-only, GET, 20s, 5MB, no downgrade; requires
  non-empty `permissions.network` (`PermissionStore.PermissionKind.network`).
- Permission summary strings match `WidgetDiscovery.permissionSummary`.
- `storage` is not a manifest permission field (per-widget sandbox, ~1MB, no
  gate) — noted; the scaffold's `"storage": true` is a tolerated unknown key.
- SDK surface from `sdk/mod.ts`: ui/action builders, mb.render/exec/storage/
  secret/timer/notify/log, handler shape `mb.widget({load, action, timer})`.

## Verify
- `swift build` → Build complete.
- `.build/debug/mbk agent-spec | head` → prints AGENTS.md.
- Embedded fallback exercised from an isolated dir (identical output).
- Did NOT git add/commit. Did not touch widgets/** or registry/index.json.
