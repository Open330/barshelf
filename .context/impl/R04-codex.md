Done. I only edited Task B-owned files:

- [schema/workflow-0.1.json](/Users/jiun/workspace/menubucket/schema/workflow-0.1.json) added for workflow DSL v1.
- [schema/widget-0.1.json](/Users/jiun/workspace/menubucket/schema/widget-0.1.json) updated for `bucket.pinned`, workflow `entry.main`, file/storage permissions, and setting types.
- [schema/uinode-0.1.json](/Users/jiun/workspace/menubucket/schema/uinode-0.1.json) updated for `drag.filePath`, `fileIcon`/`fileThumbnail`, `modifiedAt`, fallback images, and object image sizes.
- [docs/WORKFLOW.md](/Users/jiun/workspace/menubucket/docs/WORKFLOW.md), [docs/WIDGET-SPEC.md](/Users/jiun/workspace/menubucket/docs/WIDGET-SPEC.md), and [README.md](/Users/jiun/workspace/menubucket/README.md) updated with the workflow contract, recent-files walkthrough, exec allowlist relationship, pin/search/settings/drag-out links.

Verification passed:

```bash
jq empty schema/widget-0.1.json schema/uinode-0.1.json schema/workflow-0.1.json
```

I did not write `.context/impl/R04-codex.md` and did not modify `Package.swift`, `Sources/`, `Tests/`, `widgets/`, `sdk/`, or `scripts/`.