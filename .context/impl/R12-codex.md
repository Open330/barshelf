Implemented W3-EXAMPLES.

Added:
- [widgets/github-status/](/Users/jiun/workspace/menubucket/widgets/github-status/widget.json): workflow `http` source for GitHub Status, `permissions.network: ["www.githubstatus.com"]`, wake trigger.
- [widgets/downloads-watch/](/Users/jiun/workspace/menubucket/widgets/downloads-watch/widget.json): workflow Downloads watcher using `refresh.triggers: [{ "fs": "~/Downloads" }]`, with orange tinted `appearance`.
- Appended both entries to [registry/index.json](/Users/jiun/workspace/menubucket/registry/index.json) with `category`, `requires`, and full permissions summaries including `network`.

Verification:
- JSON parse passed for both manifests, both workflows, and registry.
- Local `jsonschema` was unavailable and `npx --no-install ajv` was not usable, so I ran a manual check against the relevant `schema/widget-0.1.json` constraints.
- `.build/debug/mbk validate widgets/github-status` passed.
- `.build/debug/mbk validate widgets/downloads-watch` passed.
- `swift build` passed with Xcode/tooling-safe flags: `DEVELOPER_DIR=... CLANG_MODULE_CACHE_PATH=... swift build --disable-sandbox --cache-path ... --manifest-cache local`.
- No git add or commit.