# R12 — W1-THEME notes

Widget theming (user- and author-adjustable appearance). Core stays UI-free;
the SwiftUI/AppKit helpers live app-side in the renderer.

## Files touched
- `Sources/MenubucketCore/WidgetAppearance.swift` (new) — the contract struct.
- `Sources/MenubucketCore/Manifest.swift` — added `appearance: WidgetAppearance?`.
- `Sources/MenubucketApp/WidgetPrefs.swift` — `appearanceOverrides` + 3 API funcs.
- `Sources/MenubucketApp/Renderer/ViewTreeRenderer.swift` — env key, accentColor
  helper, accent + density application.
- `Sources/MenubucketApp/WidgetSettingsView.swift` — Appearance section.
- `Tests/MenubucketCoreTests/WidgetAppearanceTests.swift` (new).
- `Tests/MenubucketAppTests/WidgetPrefsTests.swift` — appearance tests + import.

## Contract as built
- `WidgetAppearance`: `Codable, Equatable, Sendable`; `Density{compact,regular}`,
  `CardStyle{plain,tinted}`; optional `accent/density/cardStyle/showHeader`;
  `merged(over:)` = self wins field-wise, nil falls through.
- Decode is **lenient via a custom `init(from:)`**: wrong-typed / unknown-enum
  fields → nil; a non-object payload → all-nil (neutral). Never throws, so both
  Manifest and prefs decode are lenient automatically.
- `Manifest.appearance` uses synthesized Codable → delegates to the lenient
  decoder; absent → nil, present-but-garbage → neutral appearance (never fails).
- `WidgetPrefs`: `appearanceOverride(for:)`, `setAppearanceOverride(_:for:)`
  (nil OR all-nil clears the entry), `effectiveAppearance(for:)` =
  override ▸ author (manifest.appearance) ▸ neutral. Persisted key
  `appearanceOverrides` is optional → old prefs.json loads unchanged; cleared to
  nil when empty. `removeAllState` clears it too.

## Renderer (neutral == pixel-identical)
- Env key `\.widgetAppearance` (default `WidgetAppearance()`); consumer
  (W2-POPUP) injects `prefs.effectiveAppearance`. Not injected → neutral.
- App-side `WidgetAppearance.accentColor: Color?` maps SF names
  (blue/purple/pink/red/orange/yellow/green/gray, +"default"→nil) and `#RRGGBB`
  (via `Color(hex:)`); unrecognized → nil → system accent.
- Accent: `nodeColor(_:accent:)` gained an optional `accent` param (default nil →
  old behavior). Applied to text/image/badge/banner foregrounds, progress ring +
  linear meter + countdown tints (`?? effectiveAccent`), and buttons via an
  `AccentTint` modifier that only tints when a custom accent is set.
- Density: `scale = compact ? 0.85 : 1` (regular = 1.0). Scales stack/section
  spacing, `NodeLayoutModifier` padding, and text/section font sizes. Regular
  scale 1.0 → all multiplications are identity.
- Verified: with a neutral appearance every code path reduces to the previous
  literal (`* 1`, `?? .accentColor`, no `.tint`), so today's render is unchanged.

## Settings UI
- "Appearance" section under manifest settings (shown for every widget): accent
  swatch row (Default + 8 system colors, a11y-labelled buttons) + hex field,
  Density segmented picker, Card style segmented picker, Show header toggle,
  "Reset to widget default" (sets draft back to author base). Save now always
  enabled; persists override (clears when draft == author base) and refreshes.
  Content wrapped in a ScrollView (maxHeight 420) so tall forms stay usable.

## Build / test
- `swift build`: Build complete (pre-existing WidgetRuntime Sendable warnings
  only; unrelated).
- `DEVELOPER_DIR=…/Xcode swift test --build-path .build-xctest`: **198/198 pass**
  (8 new WidgetAppearanceTests, 6 new/expanded WidgetPrefsTests cases).

## Notes for W2-POPUP
- Read `\.widgetAppearance` + inject `prefs.effectiveAppearance(for:)` on each
  card; consume `cardStyle` (tinted wash) and `showHeader` at the card level —
  the renderer already handles accent + density inside the tree.
