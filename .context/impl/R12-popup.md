# R12 — W2-POPUP (popup visual refresh)

Owner: W2-POPUP. Files edited (exclusive): `RootView.swift`, `PopupSurface.swift`,
`ToastCenter.swift`. Build: `swift build` passes. Screenshot harness renders
light + dark without crash.

## What changed

### 1. Chrome (RootView header/footer)
- Header and footer now sit on `.bar` material with the existing hairline
  `Divider()`s, so they read as one continuous toolbar around the scrolling
  cards.
- Header composes bucket title + an inline `"n of m"` page indicator
  (`.caption` secondary, shown only when `count > 1`, a11y-labelled). Search /
  Refresh-all buttons unchanged on the right.
- Footer vertical padding tightened 8→6; +/gear/chevrons/dots unchanged.
- `header(for:)` signature is now `header(for:index:count:)`; call site updated.

### 2. Cards (WidgetCardView)
- Consumes theming via `runtime.prefs.effectiveAppearance(for: widget.manifest)`
  and injects it with `.environment(\.widgetAppearance, appearance)` so
  `ViewTreeRenderer` picks up accent/density.
- `cardStyle == .tinted` → accent wash (`cardAccent.opacity(0.12)`) over the
  neutral control background. `cardAccent = appearance.accentColor ?? .accentColor`.
- `showHeader == false` hides the card header row; refresh stays reachable via
  the context menu ("Refresh").
- `density == .compact` → content insets 12→8 (`contentInset`).
- Neutral softening: 10pt corner radius, `Color.secondary.opacity(0.12)`
  hairline border, subtle shadow (`.black.opacity(0.08)`, r3, y1), 12pt insets.
- Header typography quieted to `.caption` secondary (was size-11 semibold) for
  both name and icon so content reads first.

### 3. States
- Loading: centered `ProgressView` + "Loading…" caption (`loadingState`),
  combined into one a11y element labelled "Loading".
- "No data yet" centered.
- Stale/error banners restyled to match the toast capsule: `.ultraThinMaterial`
  fill + colored strokeBorder (orange 0.35 / red 0.35), 8pt radius, 8pt padding.

### 4. Motion
- Page-change spring untouched (pagerStrip).
- Reveal highlight softened: border → `cardAccent.opacity(0.8)` (was solid
  `.accentColor`), same 0.4s easeInOut.
- Per-card refresh button hidden at rest (`.opacity(isHovering ? 1 : 0)`),
  revealed on `.onHover` with a 0.15s fade. Kept in the accessibility tree at
  rest (opacity, not conditional removal); `.help`/`.accessibilityLabel` intact.

### 5. Size / harness
- Popup frame stays 360×480 (unchanged).
- `PopupSurface.swift`, `ToastCenter.swift`: no functional change needed; toast
  capsule style (in RootView.toastOverlay) is the reference the card banners now
  echo. Left ToastCenter as the message bus it is.

## Preserved behavior
Pager/swipe/keyboard, pinned row + overflow, ⌘F search overlay, welcome card,
full context menu incl. R11 items (pin/disable/move/reveal/remove), reveal
highlight flash, toast overlay, footer +/gear entry points via existing shims.

## Verification
- `swift build` → Build complete.
- `.build/debug/barshelf screenshot /tmp/r12-shots` → popover-light/dark +
  builder PNGs, no crash. Harness shares the card layer (soft borders, quiet
  headers, hover-hidden refresh visible in both light and dark); it uses its own
  header/footer mock so the "n of m" chrome text is only exercised via build.
