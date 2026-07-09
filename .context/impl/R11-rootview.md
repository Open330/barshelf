# R11 — W2-ROOTVIEW implementation notes

Owner: Claude (opus). Files edited: `RootView.swift`, `ActionRouter.swift`; new `ToastCenter.swift`.
Build: `swift build` clean.

## 1. Extended card context menu (`WidgetCardView.cardContextMenu`)
- Existing Pin/Settings/Refresh kept, then a Divider and R11 actions:
  - **Disable/Enable** — text reflects `runtime.prefs.isDisabled`; toggles via
    `runtime.setWidgetDisabled(id, !isDisabled)`.
  - **Move to Bucket ▸** — submenu over `runtime.allGroups`; each calls
    `runtime.moveWidget(id:toGroup:)`. Divider + **New Bucket…** opens a
    `.alert` with a `TextField` (`newBucketName`), whose Move button trims and,
    if non-empty, calls `moveWidget`.
  - **Reveal in Finder** — `runtime.widgetDirectory(for:)` +
    `NSWorkspace.activateFileViewerSelecting`.
  - **Remove Widget…** (`role: .destructive`) → confirmation `.alert`; on Remove,
    `try runtime.removeWidget(id:)`, errors captured in `removeError` and shown in
    a second alert (Binding get/set clears on dismiss).

## 2. Footer entry points (`footer` + `addWidgetMenu`)
- Footer HStack now: `addWidgetMenu` (plus), chevron.left … [dots centered] …
  chevron.right, gear. Two controls each side keep dots centered; spacing 6, still
  fits 360pt (built + linked clean).
- `addWidgetMenu` = `Menu` (borderlessButton, `.menuIndicator(.hidden)`, `.fixedSize()`)
  with Widget Gallery… / Install from URL… / Create Widget… (same targets as the
  empty-state CTAs). Gear → `AppSettingsWindowController.shared.show(runtime:)`.
- `.help` + `.accessibilityLabel` on plus, gear, and both chevrons.

## 3. pendingReveal jump + highlight flash
- `@State highlightedID`; `.onReceive(runtime.$pendingReveal)` → `revealAndFlash`:
  jumps pager to the page containing the id, sets `highlightedID`, sets
  `runtime.pendingReveal = nil` (so repeat reveals re-fire), clears after 1.5s.
- `WidgetCardView` gained `isHighlighted: Bool = false` (default keeps pinned-row
  callers unchanged). Border overlay draws accent @ lineWidth 2 when highlighted,
  `.animation(.easeInOut(0.4), value: isHighlighted)` for the fade.

## 4. Pinned overflow (`pinnedOverflow`)
- When `pinned.count > 2`, a "+N pinned hidden" borderless caption button below the
  2-card strip jumps to the bucket page of the first still-visible pinned widget
  beyond the strip (skips disabled/pageless ones). `.help` + a11y label present.

## 5. ToastCenter + capsule + copy toast
- `ToastCenter` (@MainActor ObservableObject, `shared`, `@Published message`,
  `show(_:)` auto-clears after 1.8s via a cancellable Task — latest wins).
- `RootView` observes `ToastCenter.shared`; `.overlay(alignment: .bottom)` renders a
  `.ultraThinMaterial` Capsule with the message, `.padding(.bottom, 46)`, opacity+move
  transition, `.animation(…, value: toast.message)`.
- `ActionRouter` copyText: `Task { @MainActor in ToastCenter.shared.show(action.toast ?? "Copied") }`;
  `NSSound.beep()` kept as audible fallback (toast is popup-only).

## 6. Welcome card tip line
- Appended a caption2 secondary line to `WelcomeCardView`:
  "Tip: right-click the menu bar icon for Settings — swipe with two fingers to switch buckets."

## Notes / constraints honored
- Only the three owned files touched; AppSettingsView/WidgetInstaller/StatusItemController
  read-only for signatures.
- macOS 13 target → `.alert` w/ TextField, `role:`, `.menuIndicator` all available.
