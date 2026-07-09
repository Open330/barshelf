Implemented W1-BUILDER in the two allowed files only.

- Added six command templates with exact preset commands in `WidgetBuilderModel`.
- Added adaptive clickable template chips above the command field in `WidgetBuilderView`.
- Selecting a template fills the command, clears stale test/mapping state, and prefills widget name/icon unless the user has edited them.
- Verified build passes with `swift build` using the Xcode toolchain/temp caches and `--disable-sandbox` for this environment. Existing warnings remain outside builder-owned files.
- Did not `git add` or commit.