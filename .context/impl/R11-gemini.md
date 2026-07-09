# R11 — W1-DOCS notes

> Note: this task was assigned to "Gemini" in R11-tasks.md, but Gemini CLI
> auth was unavailable in this environment. Completed by Claude as a fallback
> (filename kept as `R11-gemini.md` per instructions).

Scope: docs only, no code touched, no `git add`/`git commit` run.

## Files edited

- `docs/GETTING-STARTED.md`
- `docs/INSTALLING-WIDGETS.md`

## GETTING-STARTED.md

1. Added a new `## 코드 없이 위젯 만들기: Widget Builder` section, inserted
   right before `## 3분 위젯: Quick Hello` (the hand-written JSON tutorial).
   Covers: opening via menu-bar icon right-click → **Create Widget…**; the
   3 steps (Source → Display → Details); the **Test run** button and JSON
   detection feedback in step 1; live preview in step 2; **Create** button in
   step 3. Frames it as the fast, no-code path, with the existing JSON
   tutorial kept as the "learn the manifest/workflow format" path. Korean
   tone/style matches the rest of the doc. Added one screenshot placeholder
   comment consistent with the doc's existing convention.
2. Added a new `### 위젯 관리` subsection under `## 기본 조작`, listing the
   widget-card right-click menu: **Pin**, **Settings**, **Disable**, **Move
   to Bucket**, **Reveal in Finder**, **Remove** (with one line each on what
   they do), plus a pointer to the Settings window's **Widgets** tab for
   list-based management (enable/disable, bucket move, reorder, remove).
   Reworded the old bullet under "기본 조작" that said "pin, settings,
   refresh" to point at this new subsection instead of duplicating a stale,
   shorter list.

## INSTALLING-WIDGETS.md

1. In "설치 중 확인하는 내용", added a sentence noting that after a
   single-widget install the popup opens automatically and jumps to /
   highlights the newly installed widget (instead of only showing the
   completion alert — that alert path is kept for multi-widget installs per
   the task spec, mentioned via the existing "완료 알림" sentence).
2. Added a short paragraph noting the Widget Gallery shows an **Update**
   button on a card when the registry version is newer than the installed
   widget's version, and otherwise keeps the existing "Installed" +
   Reinstall behavior.

## Verification

- `git diff --stat` confirms only the two docs files changed (29 / 4 line
  diffs respectively).
- No Swift files were opened for editing; `WidgetBuilderView.swift` was only
  read to verify the exact step names (Source/Display/Details), the source
  kinds (command/folder/staticText), the Test run button, and the live
  preview panel, so the doc text matches actual UI behavior.
