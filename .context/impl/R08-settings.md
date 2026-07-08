# R08 Settings/Gallery Implementation Notes

- Added `install.bundled` support to registry entries and gallery installs.
  Packaged `Resources/widgets/<name>` and development `./widgets/<name>` are
  tried before falling back to `install.url`.
- Added app-wide `AppPrefs` persistence at
  `~/Library/Application Support/menubucket/app-prefs.json`.
- Added "Settings..." status-menu window with General, Performance, and
  Monitoring tabs.
- Wired `refreshMultiplier` and `pauseWhenClosed` into interval scheduling,
  wake handling, and `staleAfter` decisions.
- Added persisted per-widget refresh stats and surfaced them to the settings
  monitoring tab.
- Added Core tests for bundled registry parsing, app preferences, refresh
  policy scaling, and refresh stats persistence.

Validation:
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
