# BarShelf quality evaluation

Evaluation started 2026-10-23 against `b79ef72` (released version 0.7.4).
This is a structured agent evaluation, not a study with recruited human users.

## Acceptance criteria

Use the same rubric before and after improvements. Each persona receives five
equally weighted scores, each out of 10:

1. Learnability and discoverability.
2. Task completion and user control.
3. Feedback and error recovery.
4. Accessibility and localization.
5. Reliability, performance, and trust.

The overall score is the arithmetic mean of all evaluated persona scores. Acceptance
requires an overall score of at least 9, every persona at least 9, and no
unresolved critical or major defect in the evaluated journeys. A blocker caps a
persona at 6; a major defect caps it at 8. Unknown or unexecuted checks remain
explicitly unverified and cannot be described as successful tests. Numerical
scores express reviewer judgment supported by evidence, not measured user
satisfaction. The target is not a reason to inflate a score or narrow away a
failed essential journey.

## Personas and journeys

| Persona | Essential journeys | Independent reviewer |
| --- | --- | --- |
| Korean first-time Mac user | Install; find the menu bar app; choose starter widgets; understand permission requests; add a useful widget. | e-ed-claude |
| Busy everyday user | Find and organize widgets; search; configure refresh; recover from a failed refresh. | e-ed-claude |
| Developer and CLI widget author | Scaffold; validate; install; inspect and fix errors; understand execution capabilities. | e-ed-codex |
| Keyboard automation migrant | Understand import scope; import supported mappings; grant access; enable; recover after restart or permission loss. | e-ed-codex |
| Keyboard-only, VoiceOver, or low-vision user | Navigate shelf and search; identify controls; reach settings; understand selection and errors. | quality-a11y (Claude; replacement for a Codex worker that did not register) |
| Privacy- and battery-conscious laptop user | Inspect and deny permissions; understand background refresh; retain control of data; update safely. | quality-a11y |
| Multi-monitor Mac power user (added in round 2) | Configure the optional Dock; switch profiles; restore the Apple Dock after exit/failure; configure and refresh desktop widgets; verify stale and sensitive data behavior. | quality-exec (independent of its execution/timer implementation work) |

## Evidence and iteration log

### Baseline

| Persona | Learn | Complete | Feedback | Access/localization | Reliability/trust | Final score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Korean first-time user | 6 | 7 | 7 | 5 | 8 | 6.6 |
| Everyday user | 7.5 | 7 | 8 | 7 | 8 | 7.5 |
| Developer | 8 | 7 | 7 | 8 | 7 | 7.4 |
| Automation migrant | 8 | 7 | 8 | 8 | 7 | 7.6 |
| Accessibility user | 7 | 7 | 5 | 7 | 8 | 6.8 |
| Privacy/battery user | 8 | 5 | 7 | 8 | 6 | 6.0 (blocker cap) |

Overall baseline: **6.98/10**, after applying the privacy blocker cap. The
first review reported 6.5 for persona 1; the five category scores average to
6.6, which is the corrected number used here. Reviewers inspected code; CLI
pack/validation and Karabiner conversion failures were also reproduced in
disposable fixtures. No baseline VoiceOver or physical keyboard test is claimed.

Baseline `swift test`: 1,015 tests, 18 skipped, zero failures (997 passed).
This demonstrates that existing automated coverage missed the defects below.

### Improvement round 1 (in progress)

| Finding | Trigger and affected source | Change / verification required |
| --- | --- | --- |
| Permission withdrawal leaves a resident script running (blocker) | Revoke or Deny after starting a script; `WidgetRuntime`, `RuntimeSupervisor` | Stop all package instances, invalidate callbacks, recheck approval on every RPC and before launch/action. Test live stub RPC denial and process shutdown. |
| Pack succeeds with missing hidden entry (major) | `entry.main = .entry.ts`; `WidgetPacker` | Preserve hidden assets, reject unsupported symlinks clearly, validate staging before replacing output; round-trip regression. |
| GitHub subfolder loses executable bits (major) | Install a shebang entry through GitHub Contents API; `HeadlessInstaller` | Apply the archive path's executable restoration to API files; compare execution behavior. |
| Karabiner silently omits media mappings (major) | A supported remap alongside a custom function-key table; `KarabinerImporter` | Reject unsupported nonempty function-key tables atomically; preserve source and saved settings. |
| Unsupported runtime passes validation | `entry.runtime = python@3`; `WidgetValidator` | Reject unsupported runtime for directories and archives. |
| Korean gallery discovery fails (major) | Search for 날씨 or 배터리; `GalleryModel` | Add localized first-party summaries/categories and Korean/English search terms; preserve third-party descriptions. |
| Starter permission requests arrive without context | Finish onboarding with gated starters; `OnboardingView` | Explain capabilities before first use, offer individual explicit Allow actions, retain pending state otherwise. |
| Shelf refresh interval cannot be chosen | Unpromoted widget settings; `Scheduler`, `WidgetPrefs`, `WidgetSettingsView` | Persist a general cadence override; preserve promotion precedence, visibility, pause and energy floors. |
| Battery pause copy contradicts policy | Pause with promoted widgets; `SettingsPages` | Explain that visible menu bar and Dock widgets continue refreshing. |
| Search selection and toast changes are silent (major) | VoiceOver typing and arrow navigation; `SearchOverlay`, `ToastCenter` | Announce result counts and selected actions, coalesce typing; test injected announcement delivery. |
| Editing relies on drag or VoiceOver actions | Keyboard-only reordering; `WidgetCardView` | Provide reachable move controls and page menu. |
| Motion/contrast preferences ignored | Page/selection/toast transitions; popup views | Honor Reduce Motion and strengthen page indicators with increased contrast. |
| Reopening a running windowless app reveals nothing | Finder reopen; `AppDelegate` | Open the shelf hub when no window is visible; verify on a disposable build. |
| Misleading recovery and getting-started instructions | Permission denied for config.json; `ErrorExplainer`; docs | Correct error priority and actionable privacy shortcut; lead with GUI installation and gallery use; remove stale version/search claims. |

Remaining checks and independent re-evaluation must be recorded before claiming
the acceptance criteria are met. Actual Korean widget content (as distinct from
gallery descriptions), VoiceOver delivery, IME composition, hardware mappings,
and installed-build performance still require explicit verification.

### Round 1 verification and independent reassessment

- Full suite in a disposable Foundation home: **1,048 tests, 1,030 passed,
  18 opt-in tests skipped, zero failures**. The three permission-withdrawal
  integration tests executed successfully, including resident process stop,
  revocation before a queued launch, and stopping later workflow sources.
- Controlled tests also covered an already-running command's delayed side
  effect, a held old request released after replacement and reapproval, and
  notification authorization returning after the original instance stopped.
- Core strict concurrency with warnings as errors passed. The separate ad-hoc
  app bundle built successfully. Version-reference checks passed.
- Korean offscreen app rendering executed. The initial gallery capture was a
  loading state, and onboarding PNGs had transparent backgrounds. The render
  harness is being corrected to include loaded gallery/search states and an
  opaque window background; those captures do not establish interactive GUI
  success.

Independent round-1 reassessment (same five categories, caps applied):

| Persona | Learn | Complete | Feedback | Access/localization | Reliability/trust | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Korean first-time | 8 | 8.5 | 8.5 | 7 | 8.5 | 8.0 (major cap) |
| Everyday | 8.5 | 8.5 | 8.5 | 8.5 | 9 | 8.6 |
| Developer | 8.5 | 8.5 | 8.5 | 8.5 | 7 | 8.0 (major cap) |
| Automation migrant | 8 | 7.5 | 8 | 8.5 | 9 | 8.2 |
| Accessibility | 8.5 | 9 | 8.5 | 8.5 | 9 | 8.7 |
| Privacy/battery | 9 | 9 | 8.5 | 9 | 8.5 | 8.7 |

Overall **8.38/10: not accepted**. The reviewer accepted the tested permission
withdrawal repairs. Remaining major findings included local credential files
being included by the new hidden-file packaging behavior, English starter
widget content/page labels, and a conditional usability problem importing
Karabiner profiles with function-key tables. A separate review found script
timers bypassing the popup-closed pause policy and retained storage/secrets
after removal. These require another implementation and verification round.

### Round 2 (in progress)

- Exclude private configuration, credentials, editor/agent settings and key
  files when packing; report excluded paths, preserve hidden code modules, and
  treat file names as operands rather than zip options.
- Localize the three starter widgets and standard page labels while retaining
  stored identities, executable commands, action payloads, and user data.
- Pause hidden script timer sources when the user selects popup-closed pause;
  resume overdue events without a burst, retain quotas, and never resurrect a
  stopped widget. Apply the latest visibility policy before loading scripts.
- Purge the removed instance's storage and secrets without erasing other
  widgets' or copies' data, stopping work before it can recreate deleted data.
- Make automatic-open and desktop staleness honor slower user cadence; copy
  cadence when duplicating and show saved custom cadence choices accurately.
- Improve missing-Deno recovery and separate manifest capability errors from
  macOS privacy errors; retain unfinished onboarding when opening the gallery.
- Bind queued script loads to an invalidatable host lifetime and wait for a
  rescan's stop barrier before loading replacements.

Round-2 changes are not covered by the round-1 test totals above. Updated
results, rendered artifacts, and an independent reassessment remain required.
The initial and round-1 totals above cover the original six personas. A seventh
persona was added to explicitly cover Dock and desktop-widget journeys; its
assessment must be included in subsequent overall scores and acceptance.

Persona 7's first source review scored **7.0/10** (8 / 7 / 6 / 7.5 / 6.5).
It found major gaps in durable Apple Dock recovery before hiding, desktop
withdrawal on permission revocation, timeline invalidation when removing the last
widget, explicit part-selection fallback, invisible desktop refresh failures,
and overflow on smaller displays. These are being repaired and tested in
parallel. Round 1's 8.38 is a historical six-persona score, not a claim about the
expanded seven-persona scope. The expanded result remains unaccepted/unscored
until all seven are reassessed against the resulting implementation.

### Round 2 integration checkpoint (2026-10-24)

- Disposable-home full suite: **1,110 tests, 1,092 passed, 18 optional tests
  skipped, zero failures** (`/tmp/barshelf-quality-round2-full-tests-final.log`).
  This run executed the three instance-removal integration tests, real
  Keychain deletion against newly generated test service names, permission
  withdrawal from cached card/Dock/menu-bar displays, desktop failure feedback
  with and without cached content, and eight offscreen Dock overflow tests.
  The earlier trial runs were not green: an added test initially ran against
  an older compiled app, then expected an untruncated menu-bar label. The
  stable run above includes the display repair and corrected precondition.
- Core strict concurrency with warnings as errors passed. The WidgetKit
  extension and preview executable built in Debug with signing disabled.
  The separate ad-hoc app (`dev.barshelf.quality`) built successfully;
  the installed release was not replaced.
- Nineteen Korean app screenshots rendered from an isolated home. Review of
  onboarding, the permission-pending popup and loaded Korean gallery search
  confirmed readable controls and matching weather search results. Desktop
  previews also rendered with compiled Korean resources; reviewed missing
  selection and unanswered-refresh states explain recovery in Korean.
  These are native offscreen renders, not evidence of VoiceOver speech,
  physical keyboard mappings, or an installed WidgetKit timeline updating.
- Withdrawing permissions now clears the shared card model and pending
  snapshot writes; unapproved menu-bar items disappear immediately. A
  request-specific token prevents an old desktop timeout clearing a newer
  refresh request.

An additional independent source review of the first six personas gave
provisional scores **8.7 / 8.7 / 8.0 / 8.6 / 8.7 / 8.8** (mean **8.58**).
This is not the seven-persona overall score and does not meet acceptance.
The developer score retains the major cap: the reviewer found that packing
to an existing directory or a package source path can delete the destination,
and repeated in-package output can include an older archive. Both are being
repaired with preservation tests. A separate Dock review identified unstable
magnification while overflowing, missing Reduce Motion handling, and recovery
feedback improvements; these follow-ups are also pending.

The checkpoint suite predates those follow-ups and the later clock-permission
copy/page-label refinements. They require fresh verification. All seven
personas still require reassessment, and the goal remains active.

### Round 3 repairs and verification in progress

A second independent seven-persona source review identified more problems,
including reapproval failing to restore a menu-bar item, Dock scroll dispatch
intercepting a card's own scrolling, insufficient guidance about desktop source
refresh, the Recent Files folder picker accepting unusable choices, and remaining
Korean display text. Its provisional overall was **7.99**; its test discussion
still referenced the superseded failing trial rather than the later green
1,110-test log. The fresh evidence was supplied for reassessment. Neither that
provisional score nor the earlier first-six score is an accepted current result.

- Approval now resynchronizes promoted items immediately and clears approval
  overlays for other copies of the same package.
- The settings editor shows allowed read roots for directory settings directly
  connected to `fs.directory`. An invalid folder remains a visible draft with
  recovery guidance; it does not replace the saved folder or block unrelated
  edits. External-command directory settings are not constrained by this UI
  helper; runtime descriptor authorization remains authoritative.
- Dock restore through the CLI now checks the system write and configuration
  save before reporting success. A failed operation retains the durable recovery
  file. The app also localizes Dock failures and offers a Restore action.
- Desktop configuration, the inspector and getting-started guide explain that
  placement alone does not keep the source running. Script timer background
  behavior and the popup-closed pause control are also explicit.
- All 30 bundled widget manifests now have Korean display tables, with matching
  gallery titles and multiword search. Script-generated display copy and some
  expression-based text require further work; manifest-table coverage alone
  does not establish that every rendered widget is translated.
- Transactional packaging, broader standard private-file exclusions, explicit
  Dock keyboard entry, scroll dispatch fixes, and settled Korean composition
  announcements are implemented or in handoff, pending integration checks.

Focused round-3 verification passed **58 tests** (51 app, 7 CLI), zero skipped
or failed. This includes folder-boundary checks, reapproval, localized recovery
and CLI recovery-record preservation, but predates subsequent directory-source
scoping, cadence-copy refinements and peer handoffs. CI is being configured to
run guarded integration tests in a disposable home rather than silently skip
them.

A live isolated-app check through the Tacto skill stopped with
`window_list_unavailable` (AX -25204). A process sample was still inside
`NSApplication` appearance initialization, before the app's launch handler.
No synthetic input was sent; the isolated process was stopped. This establishes
neither a successful GUI journey nor a confirmed BarShelf launch defect.

### Round 4: live journeys and installation identity

A fresh independent seven-persona audit gave provisional scores
**9.0 / 9.1 / 9.1 / 8.8 / 8.7 / 8.9 / 8.7** (mean **8.90**).
This predates the live gallery finding below and is not an accepted current
result. Physical keyboard, VoiceOver speech, multiple displays and installed
WidgetKit behavior still need evidence.

Round 3's corrected full suite executed **1,139 tests: 1,121 passed, 18 skipped,
zero failed**. Subsequent focused checks passed 32 localization tests and six
storage/removal recovery tests. These results do not replace the fresh full
suite required after the following changes.

The isolated Korean app successfully opened onboarding and the gallery. A
native accessibility click approved only the Today widget in the disposable
profile; a fresh accessibility observation and the profile's permission record
confirmed the change. Opening the gallery preserved unfinished onboarding.
Native text insertion of `날씨 위젯` updated the actual search results from 26
to one weather card. Merely setting the text field's accessibility value had
not updated the binding and was not counted as a search pass. This checks the
native search journey, not physical Korean IME composition or VoiceOver speech.

That live journey exposed a major installation-state defect: the three seeded
widgets were shown as uninstalled because their folder names differ from their
manifest IDs. Installation discovery now reads validated manifests in a single
scan. Updates reuse the discovered regular package directory; linked packages
are recognized but require explicit manual update, and occupied, malformed or
mismatched destinations cannot be overwritten. Copy aliases remain distinct.
Tests cover seeded folders, links, occupied paths, invalid IDs and reinstall
preservation. The first round-4 full run found two additional failures (minimum
host metadata and temporary-directory URL spelling); both were corrected and
the focused installation checks passed. A fresh full run and live recheck are
pending; the major finding is not declared closed by source changes alone.

Failed removal now releases the storage tombstone for the surviving widget,
so a failed secret purge does not leave its storage permanently unwritable.
Other purged IDs remain blocked. Workflow locale is now explicit, and dynamic
status text uses locale only for display; command arguments, provider data and
stored values retain their original meaning.

A 20.02-second idle sample of the isolated three-starter profile with the gallery
open showed less than the CPU counter's measurement resolution (0.00 seconds
reported, approximately <0.05% of one core) and stable 143.02 MiB RSS. This is
not a benchmark of the user's full installed configuration. Only one physical
display was attached, so multiple-display behavior remains unverified.

The installed 0.7.4 app and real user configuration remain unchanged. Current
quality changes are neither committed, pushed nor released. The 9/10 goal
remains active.

Round-4 verification subsequently completed: **1,152 executed, 1,134 passed,
18 skipped, zero failed** (671 Core, 408 app, 73 CLI). Strict Core concurrency
with warnings treated as errors, string synchronization, version consistency
and whitespace checks passed. A Debug test bundle with the distinct
`dev.barshelf.quality` identifier was signed with the existing Developer ID and
passed strict deep signature verification. Its temporary signing keychain was
removed after building; the installed release was not replaced.

The rebuilt live gallery now shows Today and Recent Files as installed.
Typing `빠른 선반` narrows the live list to one card, which also shows installed.
All three starter installation identities therefore match the runtime count.
Opening a weather detail was not executed: Tacto classified the card as an
installation and returned `contract_effect_mismatch` before acting. This is
recorded as a tooling limitation, not a successful detail/install journey;
no alternative input route was used to bypass it. Update/removal GUI journeys
still need verification, despite the passing installation regression tests.

The follow-up audit found the same folder-name assumption in Add Instance.
That path now resolves a validated installed manifest and refuses development
checkouts. Regression coverage duplicates a short-named package, updates it in
place and checks both instances; another case preserves an ID-named foreign
package while pointing the alias at the correct folder. The first new run
caught a test assertion comparing equivalent directory URLs with different
trailing slashes; the comparison now uses resolved filesystem paths. A fresh
full run covers this repair and the subsequent app-only copy changes.

The three new installation refusal states have actionable Korean app copy,
while CLI errors retain raw English diagnostics. The app's headless install
output now prints the actual installation directory after an in-place update.
Multiline settings controls also have explicit accessibility names; live
accessibility-tree rechecking is pending the latest build. These changes do not
establish physical VoiceOver speech behavior.

The later full run passed **1,154 tests: 1,136 passed, 18 skipped, zero failed**,
including both Add Instance regressions. A later single accessibility-label
addition for the menu-bar icon picker is not included in that full-run count.
Live checks of the latest test app show named Korean popup-height, login and
copy-sound controls. Advanced settings also expose named refresh-speed and
pause controls, and show the script-timer background behavior in Korean.

Opt-in performance/native-sampling checks passed 11 tests without skips.
On this Mac, 1,000 Dock icon/name requests took 2,534.30 ms without the cache
and 2.18 ms through the cache. Runtime sensor sampling averaged 15.92 ms for
an open detailed card, 6.03 ms for all menu-bar groups and 2.22 ms for CPU-only
menu-bar sampling. System/sensor workflow evaluation took roughly 0.46/0.53 ms
while hidden, with detailed visible sensors at 1.21 ms. These are local
microbenchmarks, not end-to-end CPU percentages or promises for other hardware.

Read-only import of the user's current local Hammerspoon profile passed its
opt-in conversion test: six bindings and keyboard type 91 were retained.
No script was saved or enabled. Live automation settings show the inactive
state, separate Save and draft controls, an accessibility-permission action,
and the connected display list. This supports migration UI/parser evidence;
it does not verify that physical remaps or restart/wake behavior work.
The menu-bar icon picker and automation enable control received explicit
accessibility labels after the last full run; they require compile/live checks,
not another claim that the 1,154-test result included these later additions.

Independent reassessment after the gallery and valid-package duplication fixes
was **8.91/10**, with persona means **9.2 / 9.1 / 8.9 / 8.8 / 8.8 / 8.9 / 8.7**.
No reviewed valid-package journey retained a confirmed major/blocker. The audit
found a further local-authoring boundary: a manually written `../…` widget ID
could derive an alias outside the widgets folder. Duplication now validates the
ID before deriving any paths, and installed-package indexing excludes invalid
IDs. The added regression loads such a local package, verifies rejection and
checks that no outside alias exists. Focused checks passed after this repair;
the independent boundary review is pending.

The compact Tacto tree does not export linked title relationships such as
`AXTitleUIElement`. A control without inline Description therefore does not
establish a missing VoiceOver name. Explicit labels are a conservative naming
improvement; neither the earlier compact tree nor the later visible descriptions
prove a VoiceOver speech failure or fix. The unexecuted hardware and speech
journeys remain unknown rather than being reported as defects or passes.

The independent boundary follow-up closed the exact invalid-ID finding after
personally inspecting the guard and **39 passing focused tests, zero skipped
or failed**. It found no new actionable defect in that bounded repair. The
8.91 score predates this closure and remains historical, not a current defect
penalty or an accepted result. The latest built app also exposes Korean
Descriptions for the menu-bar icon picker and automation enable checkbox.
Its isolated test process was stopped after verification. No release or real
user configuration was replaced. Essential physical-keyboard, VoiceOver,
multi-display and installed WidgetKit evidence is still outstanding.

### Remaining acceptance evidence

The prior turn made concrete progress (code repairs, independent closure and
executed test/UI evidence). The following essential checks are still pending;
repeating source review or changing their wording cannot substitute for them.

| Environment and journey | Evidence needed for acceptance | Current state |
| --- | --- | --- |
| Signed automation build on the user's keyboard | English and Korean Fn+I/J/K/L, repeat, Shift selection, release Fn before the letter, disable/re-enable and restart/wake; active checkmark must match working runtime. | Local profile conversion passed; physical behavior not executed. |
| Keyboard navigation and VoiceOver | Reach shelf/search/settings and Dock controls without pointer input; hear control name, role, value, selection and error announcements without duplicates; verify Korean composition. | Native compact AX observations and offscreen tests passed; speech and physical traversal not executed. |
| Two attached displays | Reach every overflowing Dock tile/Trash, focus and scroll correctly, switch profiles, reconnect a display, retain valid placement and restore the Apple Dock. | One physical display available; offscreen geometry/focus/routing checks passed. |
| Installed signed WidgetKit extension | Configure a specific widget/part, request refresh, observe new timestamp or actionable timeout, then revoke/remove and confirm sensitive content disappears. | Publisher/protocol tests and previews passed; installed timeline not executed. |
| Gallery detail/install/remove | Open a detail-only state, install one widget without implicit permission approval, update the existing folder and remove cleanly. | Starter installed-state repair live-verified; regression tests pass. Detail dispatch blocked by the automation tool's installation keyword classification. |

Record the build identifier, environment, exact action and observed result for
each check. A failure needs reproduction and repair; an unavailable environment
remains pending. The installed release must not be described as validating
unreleased source changes merely because its version already runs correctly.

### Complete signed candidate (2026-10-24)

The next continuation built the current source in Release configuration with
the WidgetKit extension included. The app, extension and both CLI binaries were
then signed with the existing Developer ID using a disposable keychain. Strict
verification passed for the complete app and CLIs. The host and extension both
report 0.7.5, the same build number, and Team ID `728FW73BS8`; a local receipt
records executable hashes and `b79ef72e3562-dirty` provenance.

The candidate is at `/tmp/barshelf-quality-candidate/BarShelf.app`, with build
log `/tmp/barshelf-quality-candidate-build.log` and receipt
`/tmp/barshelf-quality-candidate/quality-candidate-receipt.json`. It is an
uncommitted local review candidate, not a notarized or published release. It
was not launched or installed over 0.7.4. Signing material was removed and the
original user keychain search list restored. This establishes optimized build,
extension packaging and signature integrity, not installed timeline behavior.

An availability question is pending for the human/hardware checks above. No
answer or elapsed wait is treated as a successful test. The goal remains active;
there is no new numerical acceptance assessment.
