---
name: barshelf-widget
description: Create or update native BarShelf menu bar widgets from a CLI, API, local files, or an interactive idea. Use for BarShelf widget manifests, workflows, exec scripts, and Deno script widgets, including validation and local installation when requested. Not for web widgets or Apple WidgetKit extensions.
---

# BarShelf widget authoring

Deliver a complete widget directory that BarShelf can load: `widget.json`, the
entry file(s), and a README with setup, settings, dependencies, and permissions.
BarShelf renders native UINode JSON; widgets do not supply HTML or draw pixels.

## Learn the host contract

Run `barshelf agent-spec` before implementing. Its output is the authoring
contract for the available host. If the CLI is missing, read `docs/AGENTS.md`
in a BarShelf checkout, or the [agent spec](https://github.com/Open330/barshelf/blob/main/docs/AGENTS.md).
Do not assume the installed skill lives inside the BarShelf repository.

Read only the additional references needed for the chosen layer. Prefer files
from the checkout or host version being targeted; online main may describe
features newer than the installed app.

| Need | File in a BarShelf checkout | Online reference |
|---|---|---|
| Manifest, settings, UINode, actions | `docs/WIDGET-SPEC.md` | [Widget spec](https://github.com/Open330/barshelf/blob/main/docs/WIDGET-SPEC.md) |
| Sources, expressions, transforms, repeating rows | `docs/WORKFLOW.md` | [Workflow DSL](https://github.com/Open330/barshelf/blob/main/docs/WORKFLOW.md) |
| Stateful script lifecycle and host APIs | `docs/SCRIPT-RUNTIME.md`, `sdk/mod.ts` | [Runtime](https://github.com/Open330/barshelf/blob/main/docs/SCRIPT-RUNTIME.md), [typed SDK](https://github.com/Open330/barshelf/blob/main/sdk/mod.ts) |
| Validation and scaffolding | `docs/CLI.md` | [CLI](https://github.com/Open330/barshelf/blob/main/docs/CLI.md) |
| Similar working widgets | `widgets/` | [Examples](https://github.com/Open330/barshelf/tree/main/widgets) |
| CLI or app setup | `docs/INSTALL.md` | [Install](https://github.com/Open330/barshelf/blob/main/docs/INSTALL.md) |

For script widgets, inspect the actual SDK exports before using `barshelf.*`,
`ui.*`, or `action.*`. The installed app also bundles `Contents/Resources/sdk/mod.ts`.
Do not invent node types, expression functions, or SDK helpers. Unknown manifest
keys may be ignored and unknown node types may render placeholders, so decoding
success alone does not establish that a feature works.

## Choose and implement

Infer the data source, display, click behavior, settings, and refresh cadence
from the request and existing widget. Ask only about missing choices that
materially affect implementation.

- Prefer **workflow** for commands, HTTPS JSON GET, directory listings, native
  telemetry, or literal data mapped into a view.
- Use **exec** when a command computes the view tree or emits data for a supported
  adapter. Ordinary CLI JSON is not automatically a UINode tree.
- Use **script** for persistent state, custom action handlers, timers, secrets,
  or notifications that a workflow cannot express. This layer requires Deno.

For a new widget, scaffold into a new directory with
`barshelf new my-widget --kind workflow` (or `exec` / `script`), then replace the
sample content and permissions. Edit existing widgets in place without
re-scaffolding them. Preserve their IDs and user-facing settings unless the
requested change needs a migration.

Give repeated rows stable IDs, keep views compact, and handle empty data,
missing setup, and source failures explicitly. Use supported native actions
for links, copy, file opening, and refresh. Choose polling intervals appropriate
to the data source; menu bar promotion can keep polling while the popover is
closed. Declare `minHostVersion` when relying on a version-gated feature.

Declare the smallest matching command/argument, network-host, filesystem-path,
and telemetry allowlists. Use `permissions.readPaths`, not the obsolete `files`
form. Host-mediated exec calls and run actions must match `permissions.exec`.
Route script capabilities through the SDK rather than bypassing the host with
direct Deno process or filesystem access. Keep credentials out of the bundle;
use existing CLI authentication or the SDK secret store as appropriate. Mark
private command output sensitive. Explain each declared permission in the README.

## Verify and deliver

Run `barshelf validate <widget-directory>` and fix reported issues until it
prints `valid:`. In a source checkout without a CLI on PATH,
`swift run barshelf validate <widget-directory>` is an alternative when the
macOS build toolchain is available.

For scripts, create a temporary import map whose `imports.barshelf` points to
the target SDK's absolute file URL, then run:

```sh
deno check --import-map /absolute/path/to/import-map.json ./my-widget/index.ts
deno fmt --check ./my-widget/index.ts
```

Do not ship a machine-specific import map; BarShelf supplies its own at runtime.
For exec widgets, check executable permissions, JSON output, and separation of
stdout (the payload) from stderr (diagnostics). Exercise representative normal,
empty, and failure cases where practical. Validation checks structure; it does
not execute the widget or prove the rendering, credentials, or permissions work.

If the request includes using or installing the widget locally, run
`barshelf install <widget-directory>` after validation and check it in BarShelf
when UI access is available. First-run capability approval is handled by the
app. A checkout's `./widgets/` dev copy takes precedence over an installed widget
with the same ID. For an authoring-only request, deliver the directory and its
install command. Only pack or publish when that is part of the request.

Report the output path, chosen layer, configuration, refresh behavior,
permissions, and checks actually performed. If the host, Deno, credentials, or
UI are unavailable, distinguish completed static checks from untested runtime
behavior rather than claiming the widget works.
