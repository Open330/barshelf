import AppKit
import Combine
import MenubucketCore

/// Live menu-bar text for promoted widgets.
///
/// The published entries are what the menu bar draws; they are recomputed on
/// every snapshot of a promoted widget. This is deliberately *not* part of
/// `WidgetRuntime`'s own `objectWillChange`: a 2 s status refresh must not
/// invalidate the popup's view tree (R05 perf), so the menu bar observes its
/// own small store.
final class MenuBarStatusStore: ObservableObject {
    @Published private(set) var entries: [MenuBarEntry] = []

    /// Widget ids actually promoted — the set the scheduler keeps polling
    /// while the popup is closed.
    ///
    /// Capped the same way the renderer caps, so a widget past `maxEntries`
    /// never holds the closed-popup exemption for a value nobody can see.
    var promotedWidgetIDs: Set<String> {
        Set(MenuBarPolicy.promoted(entries).map(\.widgetID))
    }

    func apply(_ entries: [MenuBarEntry]) {
        guard self.entries != entries else { return }
        self.entries = entries
    }
}

/// Owns every menu-bar status item: the main BarShelf item, whose title is the
/// shared live strip, and one extra item per widget the user split out.
///
/// Click handling for the main item stays in `StatusItemController` — this
/// class only draws into it, so the popup toggle keeps a single owner.
///
/// Like `Scheduler`, every entry point runs on the main queue; the owning
/// `StatusItemController` is constructed in `applicationDidFinishLaunching`
/// and the entry subscription is delivered on `RunLoop.main`.
final class MenuBarController {
    /// Width of the main item when it shows the mark alone.
    static let iconOnlyLength: CGFloat = 28

    /// A promoted widget's own item was clicked — reveal it in the popup.
    /// Left click on a separate item. The button comes with it so the caller
    /// can hang a popover off that item rather than off the BarShelf one.
    var onSelect: ((String, NSStatusBarButton) -> Void)?
    /// Right-click on one of the separate items. The button is passed so the
    /// caller can anchor a context menu to the item that was clicked.
    var onContextMenu: ((NSEvent, String, NSStatusBarButton) -> Void)?

    private let mainItem: NSStatusItem
    /// Extra status items, keyed by widget id.
    private var separateItems: [String: NSStatusItem] = [:]
    private var mainSymbol: String = AppPreferences.defaultMenuBarSymbol
    /// Symbol the main button currently carries. The brand mark is drawn into
    /// a bitmap, so it is only rebuilt when the choice actually changes — not
    /// on every 2 s strip redraw.
    private var appliedSymbol: String?
    private var currentEntries: [MenuBarEntry] = []
    /// What each separate item last drew, keyed by widget id, and what the
    /// main item's strip last drew (nil until it is first drawn).
    ///
    /// A status item is not cheap to touch. Since macOS 26 each one is drawn
    /// by the menu bar host through a scene "replicant", and every property
    /// set — image, title, length, tooltip — is a round trip that redraws the
    /// replicant and commits a Core Animation transaction. `redraw()` used to
    /// re-set every property of every item whenever *any* promoted widget
    /// changed, so a CPU reading ticking every two seconds also redrew the
    /// memory and temperature items and the (empty) strip. Profiled, that was
    /// the single largest cost of a promoted widget: ~35% of its CPU.
    private var appliedSeparate: [String: MenuBarEntry] = [:]
    private var appliedStrip: [MenuBarEntry]?
    /// The widest each separate item has drawn since its layout last changed.
    ///
    /// Digit padding holds a reading's width still across its normal range;
    /// this covers the rest — a `100%`, a rate that changes units. Once an item
    /// has needed a width it keeps it, so the one unusual reading moves the bar
    /// once instead of on every tick that crosses the boundary. A change to
    /// anything but the values (style, label, icon, presentation) starts over.
    private var widthFloors: [String: WidthFloor] = [:]

    /// A width an item has needed, and when readings stopped needing it.
    struct WidthFloor: Equatable {
        var layout: MenuBarEntry
        var width: CGFloat
        /// When the first narrower reading was drawn after the wide one; nil
        /// while the current reading still needs `width`.
        ///
        /// The countdown starts at the drop, not at the last wide draw. An
        /// unchanged reading is never redrawn, so a CPU pinned at 100% for
        /// minutes produces no draws to renew a timestamp — counting from the
        /// last wide draw let the item snap narrow the moment it came off
        /// 100%, which is exactly the jolt the hold exists to prevent.
        var releasedAt: Date?
    }

    /// How long an item keeps a width a reading no longer needs. Holding it
    /// forever made one 100% CPU spike leave the item three digits wide all
    /// day; not holding it at all would let a reading hovering at 99/100
    /// shove the bar every tick. A minute bounds that to once a minute.
    static let widthFloorHold: TimeInterval = 60

    /// The floor to draw with right now: the kept width while it is still
    /// held and the layout has not changed, otherwise none.
    static func activeFloor(_ floor: WidthFloor?, layout: MenuBarEntry, now: Date) -> CGFloat {
        guard let floor, floor.layout == layout else { return 0 }
        if let released = floor.releasedAt, now.timeIntervalSince(released) > widthFloorHold {
            return 0
        }
        return floor.width
    }

    /// The floor to keep after drawing a reading whose own width is `natural`.
    static func nextFloor(
        _ floor: WidthFloor?, layout: MenuBarEntry, natural: CGFloat, now: Date
    ) -> WidthFloor {
        let held = activeFloor(floor, layout: layout, now: now)
        // This reading needs at least what is held: hold it, no countdown.
        if natural >= held { return WidthFloor(layout: layout, width: natural, releasedAt: nil) }
        // Narrower while held: the countdown starts on the first such reading.
        guard var kept = floor else { return WidthFloor(layout: layout, width: natural, releasedAt: nil) }
        if kept.releasedAt == nil { kept.releasedAt = now }
        return kept
    }

    init(mainItem: NSStatusItem) {
        self.mainItem = mainItem
    }

    /// The SF Symbol / brand mark shown on the main item (app preference).
    func setMainSymbol(_ symbol: String) {
        mainSymbol = symbol
        redraw()
    }

    func apply(_ entries: [MenuBarEntry]) {
        guard currentEntries != entries else { return }
        currentEntries = entries
        redraw()
    }

    private func redraw() {
        let (strip, separate) = MenuBarPolicy.partition(currentEntries)
        applyStrip(strip)
        applySeparateItems(separate)
    }

    // MARK: - Main item (shared strip)

    private func applyStrip(_ entries: [MenuBarEntry]) {
        guard let button = mainItem.button else { return }
        if appliedSymbol != mainSymbol {
            BarShelfStatusIcon.configure(
                button, symbol: mainSymbol, fallback: AppPreferences.defaultMenuBarSymbol
            )
            appliedSymbol = mainSymbol
            // `configure` resets the image position, so the strip has to be
            // laid out again even if its entries did not change.
            appliedStrip = nil
        }
        guard appliedStrip != entries else { return }
        let previous = appliedStrip
        appliedStrip = entries
        guard !entries.isEmpty else {
            mainItem.length = Self.iconOnlyLength
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.toolTip = nil
            button.setAccessibilityLabel(BarShelfStatusIcon.accessibilityName)
            return
        }
        let tooltip = MenuBarPolicy.tooltip(for: entries)
        if button.toolTip != tooltip { button.toolTip = tooltip }
        let spoken = entries.map(MenuBarPolicy.accessibilityText).joined(separator: "; ")
        if previous.map({ $0.map(MenuBarPolicy.accessibilityText).joined(separator: "; ") != spoken }) ?? true {
            button.setAccessibilityLabel("\(BarShelfStatusIcon.accessibilityName), \(spoken)")
        }
        // Raw numeric samples and spoken descriptions are not necessarily a
        // visible change after the user's precision/value settings apply.
        if let previous, previous.count == entries.count,
           zip(previous, entries).allSatisfy({ Self.drawsIdentically($0, $1) }) { return }
        mainItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.attributedTitle = Self.attributedStrip(entries)
    }

    /// Whether an icon override names an SF Symbol or is literal text.
    ///
    /// This is the one question Core cannot answer — it needs AppKit to know
    /// whether a symbol by that name exists — so the split happens here. A
    /// name that resolves becomes a tinted template image; anything else is
    /// drawn as text, which is how an emoji gets into the menu bar.
    static func symbolImage(
        named name: String, describedAs description: String, tint: NSColor? = nil
    ) -> NSImage? {
        guard !name.isEmpty else { return nil }
        guard let image = NSImage(
            systemSymbolName: name, accessibilityDescription: description
        ) else { return nil }
        guard let tint else {
            image.isTemplate = true
            return image
        }
        // A coloured symbol cannot be a template, and a non-template does not
        // invert while the item is held open. That is the cost of asking for a
        // colour, and only the widgets that ask pay it.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            tint.set()
            rect.fill()
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// The literal glyph an entry contributes, or nil when its icon is a
    /// symbol (or absent).
    static func textGlyph(for entry: MenuBarEntry) -> String? {
        guard let override = entry.iconOverride, !override.isEmpty else { return nil }
        return symbolImage(named: override, describedAs: entry.name) == nil ? override : nil
    }

    /// The shared strip is text only — one cell per widget, separated by a
    /// middle dot. SF Symbol icons belong to the separate items, where AppKit
    /// tints a template image for free; an emoji is text, so it is drawn here
    /// like any other characters.
    ///
    /// Colors stay dynamic (`labelColor` and friends) so the menu bar resolves
    /// them for its own appearance at draw time. Stale entries drop to the
    /// tertiary color: a frozen reading must not pass for a live one.
    static func attributedStrip(_ entries: [MenuBarEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for entry in entries {
            let cell = MenuBarPolicy.stripCell(entry, glyph: textGlyph(for: entry))
            guard !cell.isEmpty else { continue }
            if result.length > 0 {
                result.append(NSAttributedString(
                    string: MenuBarPolicy.stripSeparator,
                    attributes: [
                        .font: stripFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ]
                ))
            }
            result.append(NSAttributedString(
                string: cell,
                attributes: [
                    .font: stripFont(for: entry.presentation),
                    .foregroundColor: color(for: entry),
                ]
            ))
        }
        return result
    }

    // MARK: - Separate items

    private func applySeparateItems(_ entries: [MenuBarEntry]) {
        let live = Set(entries.map(\.widgetID))
        for (id, item) in separateItems where !live.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            separateItems.removeValue(forKey: id)
            appliedSeparate.removeValue(forKey: id)
            widthFloors.removeValue(forKey: id)
        }
        for entry in entries {
            let item = separateItems[entry.widgetID] ?? makeSeparateItem(for: entry.widgetID)
            separateItems[entry.widgetID] = item
            // Only the widget whose reading moved is redrawn. Images are drawn
            // through a handler, so an unchanged item still follows a light /
            // dark menu bar switch without being touched here.
            let previous = appliedSeparate[entry.widgetID]
            guard previous != entry else { continue }
            appliedSeparate[entry.widgetID] = entry
            guard let button = item.button else { continue }
            let tooltip = MenuBarPolicy.tooltip(for: [entry])
            if button.toolTip != tooltip { button.toolTip = tooltip }
            // Tooltips say more than the item shows — the System widget's
            // names CPU, memory *and* disk, the Sensors one carries a decimal —
            // so they change on refreshes where the drawn reading does not. A
            // tooltip-only change must not redraw: that was most of the redraws
            // left, e.g. the RAM item repainting every time CPU moved.
            // Spoken values can change while activity dots draw identically.
            // Update accessibility independently of the bitmap redraw gate.
            let spoken = MenuBarPolicy.accessibilityText(entry)
            if previous.map({ MenuBarPolicy.accessibilityText($0) != spoken || $0.name != entry.name }) ?? true {
                button.setAccessibilityLabel(spoken.isEmpty ? entry.name : "\(entry.name), \(spoken)")
            }
            if let previous, Self.drawsIdentically(previous, entry) { continue }
            // No `length` here: the item is created variable-length, and every
            // assignment — even of the same value — re-measures the replicant.
            // The override wins over the widget's own symbol, and an empty
            // override means the user asked for no icon at all.
            let symbolName: String? = entry.iconOverride.map { $0.isEmpty ? nil : $0 }
                ?? entry.symbol
            let symbolImage = symbolName.flatMap {
                Self.symbolImage(
                    named: $0, describedAs: entry.name,
                    tint: entry.tint.map(Self.nsColor(for:))
                )
            }
            let glyph = symbolImage == nil ? Self.textGlyph(for: entry) : nil
            let mode = entry.presentation.effectiveWidth
            let layout = Self.layoutSignature(entry)
            let now = Date()
            let floor = mode == .fit ? 0
                : Self.activeFloor(widthFloors[entry.widgetID], layout: layout, now: now)
            if entry.style == .stacked || entry.style == .metrics {
                // One image carries both rows *and* the symbol, because a
                // button has room for only one image and the rows have to sit
                // beside it rather than under it. Assigned once: each image
                // set is a replicant redraw and a re-measure.
                let draw = { (minimum: CGFloat) -> NSImage in
                    Self.drawnImage(entry, symbol: symbolImage, glyph: glyph, minimumWidth: minimum)
                }
                // Images are drawn lazily, so asking one for its size costs
                // only the text measurement: this is the reading's own width.
                let natural = draw(0).size.width
                let image = floor > natural ? draw(floor) : draw(0)
                button.image = image
                if button.attributedTitle.length > 0 {
                    button.attributedTitle = NSAttributedString(string: "")
                }
                if button.imagePosition != .imageOnly { button.imagePosition = .imageOnly }
                // The floor for a drawn item is the *image* width — the
                // button adds its own margins around it, and remembering the
                // item length instead would feed those margins back into the
                // next image and widen it on every redraw.
                if mode != .fit {
                    widthFloors[entry.widgetID] = Self.nextFloor(
                        widthFloors[entry.widgetID], layout: layout, natural: natural, now: now
                    )
                }
                // Exactly the image's width. The button would otherwise add
                // its own inset on both sides, on top of the image's padding
                // and the system's spacing between items.
                Self.applyLength(to: item, button: button, mode: mode, floor: 0,
                                 exact: ceil(image.size.width))
            } else {
                // A chart takes the icon's place in front of the text, beside
                // the icon when there is one.
                button.image = Self.leadingImage(entry, symbol: symbolImage, height: NSStatusBar.system.thickness)
                let title = NSAttributedString(
                    string: MenuBarPolicy.stripCell(entry, glyph: glyph),
                    attributes: [
                        .font: Self.stripFont(for: entry.presentation),
                        .foregroundColor: Self.color(for: entry),
                    ]
                )
                button.attributedTitle = title
                button.imagePosition = Self.imagePosition(
                    hasImage: button.image != nil, hasLabel: title.length > 0
                )
                // Text has no image to widen, so its floor is the item length.
                // Fixed adds whatever the title is short of its column.
                var textFloor = floor
                if mode == .fixed {
                    let shortfall = CGFloat(entry.presentation.effectiveFixedWidth) - title.size().width
                    textFloor = max(textFloor, ceil(button.fittingSize.width + max(shortfall, 0)))
                }
                let natural = Self.applyLength(to: item, button: button, mode: mode, floor: 0, measureOnly: true)
                _ = Self.applyLength(to: item, button: button, mode: mode, floor: textFloor)
                if mode != .fit {
                    widthFloors[entry.widgetID] = Self.nextFloor(
                        widthFloors[entry.widgetID], layout: layout, natural: natural, now: now
                    )
                }
            }
            if mode == .fit { widthFloors.removeValue(forKey: entry.widgetID) }

        }
    }

    /// Sets an item's length only when it changes.
    ///
    /// A variable-length item is re-measured by AppKit on every image or
    /// title change — `_adjustLength`, ~11% of a promoted widget's CPU in a
    /// profile — even when the width came out the same. With the width held
    /// steady, the item gets an explicit length and is left alone until that
    /// length actually moves. `fit` keeps the old variable length.
    /// `exact` sets the length outright (drawn items: the image's width);
    /// otherwise it is the button's fitting width, at least `floor`.
    /// `measureOnly` returns that width without touching the item.
    @discardableResult
    private static func applyLength(
        to item: NSStatusItem, button: NSStatusBarButton, mode: MenuBarWidthMode,
        floor: CGFloat, exact: CGFloat? = nil, measureOnly: Bool = false
    ) -> CGFloat {
        let length = exact ?? max(ceil(button.fittingSize.width), floor)
        if measureOnly { return length }
        guard mode != .fit else {
            if item.length != NSStatusItem.variableLength {
                item.length = NSStatusItem.variableLength
            }
            return item.length
        }
        if abs(item.length - length) > 0.5 { item.length = length }
        return length
    }

    /// An entry with its values blanked: what decides an item's layout, as
    /// opposed to what it currently reads.
    static func layoutSignature(_ entry: MenuBarEntry) -> MenuBarEntry {
        var layout = entry
        layout.label = nil
        layout.tooltip = nil
        layout.tint = nil
        layout.isStale = false
        // A chart's width is fixed; its points are readings, not layout.
        layout.history = []
        layout.chartScale = nil
        layout.metrics = entry.metrics.map { metric in
            var metric = metric
            metric.value = ""
            metric.number = nil
            metric.tint = nil
            metric.active = nil
            metric.accessibilityLabel = nil
            return metric
        }
        return layout
    }

    /// Whether two entries draw the same item — everything but the tooltip,
    /// which is not drawn.
    static func drawsIdentically(_ lhs: MenuBarEntry, _ rhs: MenuBarEntry) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.tooltip = nil
        rhs.tooltip = nil
        lhs.metrics = lhs.metrics.map(Self.drawnMetric)
        rhs.metrics = rhs.metrics.map(Self.drawnMetric)
        // Formatting and row overrides are already resolved into visible
        // strings/tints/order; what is left that changes the drawing is the
        // geometry and type.
        lhs.presentation = Self.drawnPresentation(lhs.presentation)
        rhs.presentation = Self.drawnPresentation(rhs.presentation)
        if lhs.style == .metrics, rhs.style == .metrics,
           !lhs.metrics.isEmpty, !rhs.metrics.isEmpty {
            // The legacy fallback is not drawn by the metric renderer.
            lhs.label = nil
            rhs.label = nil
            lhs.prefix = nil
            rhs.prefix = nil
        }
        return lhs == rhs
    }

    private static func drawnPresentation(_ p: MenuBarPresentation) -> MenuBarPresentation {
        MenuBarPresentation(
            valueWidth: p.valueWidth, width: p.width, digits: p.digits,
            alignment: p.alignment, weight: p.weight, size: p.size,
            numberAlignment: p.numberAlignment, chart: p.chart
        )
    }

    private static func drawnMetric(_ metric: StatusMetric) -> StatusMetric {
        StatusMetric(label: metric.label, value: metric.value, tint: metric.tint, active: metric.active)
    }

    static func imagePosition(hasImage: Bool, hasLabel: Bool) -> NSControl.ImagePosition {
        switch (hasImage, hasLabel) {
        case (true, true): return .imageLeading
        case (true, false): return .imageOnly
        default: return .noImage
        }
    }

    static func autosaveName(for widgetID: String) -> String {
        "BarShelf.\(widgetID)"
    }

    private func makeSeparateItem(for widgetID: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A name per widget is what lets macOS remember where the user put
        // each item (it saves the position when the item is ⌘-dragged).
        // Without one only the main item kept its place: an arrangement was
        // lost at the next launch or update, and an item could come back on
        // the far side of other apps' icons.
        item.autosaveName = Self.autosaveName(for: widgetID)
        // A name remembered as hidden would keep the item out of sight for
        // good; BarShelf decides visibility, not a stale preference.
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(separateItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleProportionallyDown
            // The button carries the widget id so one action serves every item.
            button.identifier = NSUserInterfaceItemIdentifier(widgetID)
        }
        return item
    }

    @objc private func separateItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let widgetID = button.identifier?.rawValue
        else { return }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp
                && event?.modifierFlags.contains(.control) == true)
        if isRightClick, let event {
            onContextMenu?(event, widgetID, button)
        } else {
            onSelect?(widgetID, button)
        }
    }

    /// Two rows drawn into a template image: the label small on top, the value
    /// beneath it.
    ///
    /// An image rather than an `attributedTitle`, for three reasons that were
    /// all visible on screen when it was text. A status item tints a *template*
    /// image for itself, so it follows a light or dark menu bar and inverts
    /// while the item is held open; an attributed string carries the colour it
    /// was given and stayed black. Clamping two differently-sized lines into
    /// the bar's height with `maximumLineHeight` cropped the ascenders off the
    /// smaller one — "Power" lost its top. And a paragraph style aligns lines
    /// against the layout width, which is not the same as aligning them to the
    /// item's left edge.
    ///
    /// Drawing places each row at a measured origin instead, so nothing is
    /// clipped and both rows start at the same x.
    /// Type sizes before fitting. The pair is scaled together so the two rows
    /// fill the bar, so these set the *ratio* more than the size.
    ///
    /// Semibold rather than regular: at menu bar sizes a regular weight reads
    /// thin against the bar's own chrome, and the value is the thing being
    /// looked at.
    static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let stackedLabelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    /// How much dimmer the label is than the value it belongs to.
    static let stackedLabelOpacity: CGFloat = 0.72
    static let staleOpacity: CGFloat = 0.4
    /// Breathing room either side of the rows. One point: the status item
    /// takes exactly the image's width, and macOS already spaces items apart,
    /// so anything more read as a gap between neighbours.
    static let stackedHorizontalPadding: CGFloat = 1
    /// Gap between the symbol and the rows beside it.
    static let stackedSymbolGap: CGFloat = 3
    /// Clearance kept above and below the rows.
    static let stackedVerticalPadding: CGFloat = 1
    /// Space between the two rows.
    static let stackedRowGap: CGFloat = 1
    /// Ceiling on the fitted value size, so a taller bar does not produce
    /// something that reads as another app's.
    static let stackedMaxValuePointSize: CGFloat = 16

    /// The height a row of this font actually inks: cap height plus whatever
    /// hangs below the baseline.
    ///
    /// Not `size().height`. That is the *line box*, which carries typographic
    /// leading and headroom above the caps — about 27% of it at these sizes,
    /// measured. Reserving the line box is why the digits came out visibly
    /// smaller than a system monitor's: a quarter of the bar was being held
    /// for space the glyphs never use.
    static func inkHeight(of font: NSFont) -> CGFloat {
        font.capHeight + abs(font.descender)
    }

    /// Distance from the top of a line box down to the top of its capitals,
    /// which is what has to be subtracted to place a row by its ink.
    private static func capInset(of font: NSFont) -> CGFloat {
        font.ascender - font.capHeight
    }

    /// The two lines an entry draws when stacked: the label, then the value.
    static func stackedLines(_ entry: MenuBarEntry, glyph: String?) -> (top: String, bottom: String) {
        // "" is the user's "no label": the value alone, as the setting says.
        // Unset falls back to the widget's name.
        var top = entry.prefix == "" ? "" : (MenuBarPolicy.normalizedPrefix(entry.prefix) ?? entry.name)
        if let glyph, !glyph.isEmpty { top = top.isEmpty ? glyph : "\(glyph) \(top)" }
        let bottom = entry.metrics.count == 1 ? entry.metrics[0].value : entry.metrics.isEmpty ? (entry.label ?? "")
            : (MenuBarPolicy.normalizedLabel(MenuBarPolicy.entryText(entry), limit: 28) ?? "")
        return (top, bottom)
    }

    /// The pair of fonts that fills `height` at the base ratio.
    static func stackedFonts(
        for height: CGFloat, presentation: MenuBarPresentation = MenuBarPresentation()
    ) -> (label: NSFont, value: NSFont) {
        let available = height - stackedVerticalPadding * 2 - stackedRowGap
        let base = inkHeight(of: stackedLabelFont) + inkHeight(of: stackedValueFont)
        guard base > 0 else { return (stackedLabelFont, stackedValueFont) }
        // Scales up as well as down: the point is to fill the bar, and the
        // ceiling stops a tall one from running away with it.
        let scale = min(
            available / base,
            stackedMaxValuePointSize / stackedValueFont.pointSize
        )
        var labelSize = stackedLabelFont.pointSize * scale
        var valueSize = stackedValueFont.pointSize * scale
        // Size trades height between the rows rather than adding any: the pair
        // already fills the bar, so a larger value takes it from the label.
        switch presentation.size {
        case .small?:
            valueSize *= 0.88
        case .large?:
            labelSize *= 0.85
            valueSize *= 1.12
        case .regular?, nil:
            break
        }
        let label = NSFont.systemFont(ofSize: labelSize, weight: .semibold)
        var value = NSFont.monospacedDigitSystemFont(
            ofSize: valueSize, weight: nsWeight(presentation.weight, default: .semibold)
        )
        // Never taller than the bar, whatever the choice.
        let ink = inkHeight(of: label) + inkHeight(of: value)
        if ink > available, inkHeight(of: value) > 0 {
            let shrink = max(available - inkHeight(of: label), 1) / inkHeight(of: value)
            value = NSFont.monospacedDigitSystemFont(
                ofSize: value.pointSize * shrink,
                weight: nsWeight(presentation.weight, default: .semibold)
            )
        }
        return (label, value)
    }

    static func nsWeight(_ weight: MenuBarWeight?, default fallback: NSFont.Weight) -> NSFont.Weight {
        switch weight {
        case .regular?: return .regular
        case .medium?: return .medium
        case .semibold?: return .semibold
        case .bold?: return .bold
        case nil: return fallback
        }
    }

    /// Where a run `width` wide starts inside a column `column` wide.
    static func alignedOffset(_ width: CGFloat, in column: CGFloat, _ alignment: MenuBarAlignment) -> CGFloat {
        switch alignment {
        case .leading: return 0
        case .center: return ((column - width) / 2).rounded(.down)
        case .trailing: return column - width
        }
    }

    /// Two rows packed into the menu bar: the label small on top, the value
    /// beneath it, both sized to fill the height they are given.
    ///
    /// An image rather than an `attributedTitle`, for three reasons that were
    /// all visible on screen when it was text. A status item tints a *template*
    /// image for itself, so it follows a light or dark menu bar and inverts
    /// while the item is held open; an attributed string carries the colour it
    /// was given and stayed black. Clamping two differently-sized lines into
    /// the bar's height cropped the ascenders off the smaller one. And a
    /// paragraph style aligns lines against the layout width, which is not the
    /// same as aligning them to the item's left edge.
    static func stackedImage(
        _ entry: MenuBarEntry,
        symbol: NSImage? = nil,
        glyph: String? = nil,
        height: CGFloat = NSStatusBar.system.thickness,
        minimumWidth: CGFloat = 0
    ) -> NSImage {
        let (top, bottom) = stackedLines(entry, glyph: glyph)
        let presentation = entry.presentation
        let (labelFont, valueFont) = stackedFonts(for: height, presentation: presentation)

        // Template images are tinted from their alpha, so an untinted drawing
        // colour only has to carry the relative weight of the two rows.
        let dim = entry.isStale ? staleOpacity : 1
        let ink = entry.tint.map(nsColor(for:)) ?? NSColor.black
        let label = NSAttributedString(string: top, attributes: [
            .font: labelFont,
            .foregroundColor: ink.withAlphaComponent(stackedLabelOpacity * dim),
        ])
        let value = NSAttributedString(string: bottom, attributes: [
            .font: valueFont,
            .foregroundColor: ink.withAlphaComponent(dim),
        ])

        let labelInk = top.isEmpty ? 0 : inkHeight(of: labelFont)
        let valueInk = bottom.isEmpty ? 0 : inkHeight(of: valueFont)
        let gap = (labelInk > 0 && valueInk > 0) ? stackedRowGap : 0
        let labelWidth = top.isEmpty ? 0 : label.size().width
        let valueWidth = bottom.isEmpty ? 0 : value.size().width

        let side = min(height - 4, 16)
        let symbolSize: NSSize = symbol == nil ? .zero : NSSize(width: side, height: side)
        var textWidth = max(labelWidth, valueWidth)
        if presentation.effectiveWidth == .fixed {
            // Content wider than the fixed column still grows it: a clipped
            // number is worse than a moved one.
            textWidth = max(textWidth, CGFloat(presentation.effectiveFixedWidth))
        }
        let chrome = stackedHorizontalPadding * 2 + symbolSize.width
            + (symbolSize.width > 0 && textWidth > 0 ? stackedSymbolGap : 0)
        // The floor the controller keeps for this item: once it has needed a
        // width, it keeps it rather than shrinking back and shoving its
        // neighbours around again.
        textWidth = max(textWidth, minimumWidth - chrome)
        let width = chrome + textWidth
        let alignment = presentation.effectiveAlignment

        let image = NSImage(
            size: NSSize(width: max(width, 1), height: height), flipped: true
        ) { _ in
            var x = stackedHorizontalPadding
            if let symbol {
                symbol.draw(
                    in: NSRect(
                        x: x, y: (height - symbolSize.height) / 2,
                        width: symbolSize.width, height: symbolSize.height
                    )
                )
                x += symbolSize.width + (textWidth > 0 ? stackedSymbolGap : 0)
            }
            // Both rows share one origin so they line up on the left, and the
            // block is centred in whatever height the bar actually has. Each
            // row is placed by the top of its capitals, so the leading the
            // line box would have added does not push the type down or shrink
            // it.
            var capTop = ((height - (labelInk + gap + valueInk)) / 2).rounded(.down)
            if !top.isEmpty {
                let dx = alignedOffset(labelWidth, in: textWidth, alignment)
                label.draw(at: NSPoint(x: x + dx, y: capTop - capInset(of: labelFont)))
                capTop += labelInk + gap
            }
            if !bottom.isEmpty {
                let dx = alignedOffset(valueWidth, in: textWidth, alignment)
                value.draw(at: NSPoint(x: x + dx, y: capTop - capInset(of: valueFont)))
            }
            return true
        }
        image.isTemplate = entry.tint == nil
        return image
    }

    /// What this entry will look like in the bar, drawn the same way the bar
    /// draws it.
    ///
    /// The settings pane shows this rather than describing it. "Label above
    /// the value" and "an SF Symbol name or an emoji" are hard to picture and
    /// easy to see, and a preview drawn by anything other than the real
    /// renderer would eventually start lying.
    static func previewImage(
        for entry: MenuBarEntry, height: CGFloat = NSStatusBar.system.thickness
    ) -> NSImage {
        let symbolName: String? = entry.iconOverride.map { $0.isEmpty ? nil : $0 }
            ?? entry.symbol
        let symbol = symbolName.flatMap {
            symbolImage(
                named: $0, describedAs: entry.name,
                tint: entry.tint.map(nsColor(for:))
            )
        }
        let glyph = symbol == nil ? textGlyph(for: entry) : nil
        if entry.style == .metrics || entry.style == .stacked {
            return drawnImage(entry, symbol: symbol, glyph: glyph, height: height)
        }
        let leading = leadingImage(entry, symbol: symbol, height: height)
        let chart = leading === symbol ? nil : leading

        let text = NSAttributedString(
            string: MenuBarPolicy.stripCell(entry, glyph: glyph),
            attributes: [
                .font: stripFont(for: entry.presentation),
                .foregroundColor: (entry.tint.map(nsColor(for:)) ?? .black)
                    .withAlphaComponent(entry.isStale ? staleOpacity : 1),
            ]
        )
        let textSize = text.size()
        let side = min(height - 4, 16)
        // A composed chart keeps its own width; a lone symbol is drawn square.
        let symbolSize: NSSize = leading == nil ? .zero
            : chart == nil ? NSSize(width: side, height: side)
            : NSSize(width: leading!.size.width, height: min(leading!.size.height, height))
        let gap = (symbolSize.width > 0 && textSize.width > 0) ? stackedSymbolGap : 0
        let width = stackedHorizontalPadding * 2 + symbolSize.width + gap + textSize.width

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            var x = stackedHorizontalPadding
            if let leading {
                leading.draw(in: NSRect(
                    x: x, y: (height - symbolSize.height) / 2,
                    width: symbolSize.width, height: symbolSize.height
                ))
                x += symbolSize.width + gap
            }
            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = entry.tint == nil
        return image
    }

    // MARK: - Drawing helpers

    /// The menu bar's own text size — matching it keeps a promoted widget from
    /// looking like a different app's status item.
    static let statusFont = NSFont.menuBarFont(ofSize: 0)
    /// The strip's own weight. Heavier than the menu bar's default text for
    /// the same reason the stacked value is: it is a reading, not a menu title.
    static let stripFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium
    )

    /// The strip font with an item's own weight and size choices applied.
    static func stripFont(for presentation: MenuBarPresentation) -> NSFont {
        guard presentation.weight != nil || presentation.size != nil else { return stripFont }
        let base = NSFont.menuBarFont(ofSize: 0).pointSize
        let delta: CGFloat = presentation.size == .small ? -1 : presentation.size == .large ? 1 : 0
        return NSFont.monospacedDigitSystemFont(
            ofSize: base + delta, weight: nsWeight(presentation.weight, default: .medium)
        )
    }

    static func color(for entry: MenuBarEntry) -> NSColor {
        guard let tint = entry.tint else {
            return entry.isStale ? .tertiaryLabelColor : .labelColor
        }
        // Stale is still stale: a frozen red is no more current than a frozen
        // black, so the colour survives and the dimming applies over it.
        let color = nsColor(for: tint)
        return entry.isStale ? color.withAlphaComponent(staleOpacity) : color
    }

    /// The system's idea of each name, so a tinted menu bar item matches the
    /// same widget's card and follows an accent-colour change.
    static func nsColor(for tint: MenuBarTint) -> NSColor {
        switch tint {
        case .accent: return .controlAccentColor
        case .good: return .systemGreen
        case .warning: return .systemOrange
        case .danger: return .systemRed
        case .secondary: return .secondaryLabelColor
        }
    }
}
