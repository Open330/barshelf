# R09 — Core Engine Robustness Hardening

Scope: `Sources/MenubucketCore/**` + `Tests/**` only. No public API signatures
changed (only additions). App target untouched.

## Real bugs found & fixed

All four are the **same root cause**: unguarded `Int(Double)` conversions. Swift's
`Int(_:)` **traps (hard crash)** on NaN, ±infinity, and finite-but-out-of-range
values. Every one is reachable from untrusted input. Empirically confirmed:
`Int(1e19)` → `Fatal error: Double value cannot be converted to Int…`.

Note: Foundation's `JSONDecoder` rejects non-representable literals like `1e400`
in JSON, but (a) **representable** doubles above `Int.max` (`1e19`,
`9999999999999999999`) pass JSON decoding, and (b) the Workflow **expression**
parser uses `Double(String)` which *does* yield `±inf` for `1e400`.

1. **JsonRpc.swift `JsonRpcID.init(from:)`** (HIGH — untrusted script stdout).
   A numeric id above `Int.max` decodes as `Double`, then `Int(doubleValue)`
   trapped → a widget script could crash the host with
   `{"jsonrpc":"2.0","id":1e19,...}`. Fix: guard `isFinite` + Int range, throw a
   clean `DecodingError` (becomes a handled parse error) instead of trapping.

2. **Workflow.swift `text.truncate` limit** (line ~300). `${text.truncate(s, 1e400)}`
   → `Double("1e400")` = ∞ → `Int(∞)` trap. Fix: `Context.clampedInt`.

3. **Workflow.swift `limit` transform count** (line ~374).
   `{"use":"limit","with":{"count":"${1e19}"}}` → trap. Fix: `clampedInt`.

4. **Workflow.swift `date.relative`** (line ~289 / `relative()` ~308).
   `${date.relative(-1e300)}` → finite-but-huge `seconds` → `Int(seconds/60)`
   trap. Fix: reject non-finite input at the call site + `clampedInt` in
   `relative()`.

5. **FileSource.swift `Params.limit`** (line ~23). `"limit": 1e19` in settings →
   `Int(count)` trap. Fix: `isFinite` guard + clamp to `Int.max`.

Shared helper added: `WorkflowEngine.Context.clampedInt(_:)` (NaN→0, saturating
to Int.min/Int.max), private, no API change.

## Additional hardening

- **Recursion-depth guard** in `Context.expand` / `evaluateExpression`
  (`maxDepth = 256`). Prevents stack-overflow crashes from pathologically nested
  templates or expressions (`count(count(count(…)))`, deeply nested arrays) in a
  malicious/broken `workflow.json`. Throws `invalidTemplate` / `badExpression`
  (reused existing cases — no new enum case, so App's exhaustive switches stay
  valid).

## Flaky-test stabilization

`Tests/MenubucketCoreTests/RuntimeSupervisorTests.swift` — bash-stub + timeout
based, seen failing intermittently under load. All `fulfillment(timeout:)` and
`RenderCapture.waitForCount(timeout:)` bumped `5/10s → 15s`. Polling loop (20 ms)
was already sound; timeouts are upper bounds so passing runs stay fast.

## Regression tests added (+6, 161 → 167)

- `WorkflowEngineTests.testTruncateLimitOutOfIntRangeDoesNotCrash`
  (`1e400`, `1e19`, `-1e400`)
- `WorkflowEngineTests.testLimitTransformCountOutOfIntRangeDoesNotCrash`
- `WorkflowEngineTests.testDateRelativeWithHugeNegativeDoesNotCrash`
- `WorkflowEngineTests.testDeeplyNestedExpressionThrowsInsteadOfOverflow` (400 levels)
- `FileSourceTests.testLimitOutOfIntRangeDoesNotCrash`
- `JsonRpcTests.testOutOfRangeNumericIdIsRejectedNotCrashed`

Each drives the exact trap path; pre-fix they abort the process (confirmed via
standalone probe), post-fix they degrade gracefully.

## Verified
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && swift test`
→ **167 tests, 0 failures**.

## Areas reviewed and judged OK (no change)

- **SafeZipExtractor**: robust. Cumulative size cap checked *before*
  decompression using declared `uncompressedSize`; `inflate` enforces
  `decodedCount == expectedSize` (declared size can't lie low); path traversal
  (`..`, absolute, backslash, empty components) rejected + standardized-path
  containment check; symlinks skipped; zip64/encrypted/exotic methods rejected;
  all readers bounds-checked. UInt16/UInt32→Int widening is safe on 64-bit.
- **ExecService**: SIGTERM→SIGKILL escalation, stdout/stderr caps, no shell.
- **JsonRpcDispatcher**, **HeadlessInstaller** download cap
  (`Int(expected)` is guarded `0 < expected ≤ maxDownloadBytes`),
  **Registry** `URL(string:)!` (compile-time constant literal).

## Open risks / not addressed

- On case-insensitive filesystems, two zip entries differing only by case can
  overwrite each other (not a traversal/security issue; last-writer-wins).
- `maxDepth = 256` is a heuristic; extremely elaborate but legitimate views
  above 256 nesting levels would be rejected (none exist in shipped widgets).
- Timeout bumps reduce flakiness but a fully hung stub would now take up to 15 s
  to fail; acceptable trade-off for determinism.
