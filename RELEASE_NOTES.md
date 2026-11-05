# BarShelf 0.7.12

Requires macOS 14+ on Apple Silicon.

## Changes

- Menu bar popups open and close immediately, without transition animations.
- The shelf initially builds the current and adjacent pages instead of every
  widget page. Visited pages retain their scroll position until the popup closes;
  jumps to distant pages go straight to the destination.
- Opening an individual widget reuses fresh cached content. Missing or stale
  content still refreshes, and widgets that load details only while visible
  continue to update when opened. Explicit Refresh remains available.
- Widget updates and repeated page selections avoid redundant UI work.

## Verification

- Full local suite: 1,218 tests, 34 skipped, no failures.
- CI: 1,218 tests, 23 skipped, no failures.
- Release app and CLI assets are Developer ID signed and Apple notarized;
  the app includes the signed desktop widget extension.
