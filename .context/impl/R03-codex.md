Implemented Task B only.

Changed:
- [sdk/mod.ts](/Users/jiun/workspace/menubucket/sdk/mod.ts:1): JSON-RPC v1 script-side runtime, `mb.widget`, `mb.render/exec/storage/secret/timer/notify/log`, pending request map, stdin/stdout framing, and schema-aligned `ui.*` helpers.
- [widgets/clock-script](/Users/jiun/workspace/menubucket/widgets/clock-script/index.ts:1): script widget manifest + Deno TS example with current time, storage-backed click counter, and 1-minute host timer.
- [docs/SCRIPT-RUNTIME.md](/Users/jiun/workspace/menubucket/docs/SCRIPT-RUNTIME.md:1): Korean runtime/protocol/SDK docs.
- [README.md](/Users/jiun/workspace/menubucket/README.md:41): added Script Widgets (M2) section only.

Validation:
- `deno check sdk/mod.ts widgets/clock-script/index.ts` could not run: `deno` is not installed (`command not found`).
- `jq . widgets/clock-script/widget.json` passed.
- Local TypeScript parser was also unavailable, so I did a manual TS syntax/protocol review.
- Did not modify `Package.swift`, `Sources/`, `Tests/`, `schema/`, `scripts/`, existing widgets, or `.context/impl/R03-codex.md`.