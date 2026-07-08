Task B is complete.

Changed only the owned files:
- Expanded [schema/widget-0.1.json](/Users/jiun/workspace/menubucket/schema/widget-0.1.json:223) for M1 manifest fields, exec allowlists, keychain, settings, and status item decoding.
- Added [schema/uinode-0.1.json](/Users/jiun/workspace/menubucket/schema/uinode-0.1.json:508) with UINode nodes, top-level `countdown`, `run`, and `copyText.clearAfterSec`.
- Added Korean author docs in [docs/WIDGET-SPEC.md](/Users/jiun/workspace/menubucket/docs/WIDGET-SPEC.md:10).
- Updated [README.md](/Users/jiun/workspace/menubucket/README.md:31) with spec links, otpeek setup, Keychain command, and controls.

Verification passed:

```bash
jq empty schema/widget-0.1.json schema/uinode-0.1.json
```

I did not create or modify `.context/impl/R02-codex.md`, `Package.swift`, `Sources/`, `Tests/`, `widgets/`, or `scripts/`.