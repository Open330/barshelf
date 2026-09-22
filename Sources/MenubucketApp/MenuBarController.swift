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
        }
        guard !entries.isEmpty else {
            mainItem.length = Self.iconOnlyLength
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.toolTip = nil
            button.setAccessibilityLabel(BarShelfStatusIcon.accessibilityName)
            return
        }
        mainItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.attributedTitle = Self.attributedStrip(entries)
        button.toolTip = MenuBarPolicy.tooltip(for: entries)
        button.setAccessibilityLabel(
            "\(BarShelfStatusIcon.accessibilityName), \(MenuBarPolicy.stripText(entries))"
        )
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
                    .font: stripFont,
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
        }
        for entry in entries {
            let item = separateItems[entry.widgetID] ?? makeSeparateItem(for: entry.widgetID)
            separateItems[entry.widgetID] = item
            guard let button = item.button else { continue }
            item.length = NSStatusItem.variableLength
            // The override wins over the widget's own symbol, and an empty
            // override means the user asked for no icon at all.
            let symbol: String? = entry.iconOverride.map { $0.isEmpty ? nil : $0 }
                ?? entry.symbol
            button.image = symbol.flatMap {
                Self.symbolImage(
                    named: $0, describedAs: entry.name,
                    tint: entry.tint.map(Self.nsColor(for:))
                )
            }
            let glyph = button.image == nil ? Self.textGlyph(for: entry) : nil
            if entry.style == .stacked {
                // One image carries both rows *and* the symbol, because a
                // button has room for only one image and the rows have to sit
                // beside it rather than under it.
                button.image = Self.stackedImage(
                    entry, symbol: button.image, glyph: glyph
                )
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
            } else {
                let title = NSAttributedString(
                    string: MenuBarPolicy.stripCell(entry, glyph: glyph),
                    attributes: [
                        .font: Self.stripFont,
                        .foregroundColor: Self.color(for: entry),
                    ]
                )
                button.attributedTitle = title
                button.imagePosition = Self.imagePosition(
                    hasImage: button.image != nil, hasLabel: title.length > 0
                )
            }
            button.toolTip = MenuBarPolicy.tooltip(for: [entry])
            // VoiceOver reads one line, so the stacked layout is flattened
            // back to "name, CPU 23%" rather than announced as two rows.
            let spoken = MenuBarPolicy.entryText(entry)
            button.setAccessibilityLabel(
                spoken.isEmpty ? entry.name : "\(entry.name), \(spoken)"
            )
        }
    }

    static func imagePosition(hasImage: Bool, hasLabel: Bool) -> NSControl.ImagePosition {
        switch (hasImage, hasLabel) {
        case (true, true): return .imageLeading
        case (true, false): return .imageOnly
        default: return .noImage
        }
    }

    private func makeSeparateItem(for widgetID: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    /// Breathing room either side of the rows.
    static let stackedHorizontalPadding: CGFloat = 3
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
        var top = MenuBarPolicy.normalizedPrefix(entry.prefix) ?? entry.name
        if let glyph, !glyph.isEmpty { top = "\(glyph) \(top)" }
        return (top, entry.label ?? "")
    }

    /// The pair of fonts that fills `height` at the base ratio.
    static func stackedFonts(for height: CGFloat) -> (label: NSFont, value: NSFont) {
        let available = height - stackedVerticalPadding * 2 - stackedRowGap
        let base = inkHeight(of: stackedLabelFont) + inkHeight(of: stackedValueFont)
        guard base > 0 else { return (stackedLabelFont, stackedValueFont) }
        // Scales up as well as down: the point is to fill the bar, and the
        // ceiling stops a tall one from running away with it.
        let scale = min(
            available / base,
            stackedMaxValuePointSize / stackedValueFont.pointSize
        )
        return (
            NSFont.systemFont(ofSize: stackedLabelFont.pointSize * scale, weight: .semibold),
            NSFont.monospacedDigitSystemFont(
                ofSize: stackedValueFont.pointSize * scale, weight: .semibold
            )
        )
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
        height: CGFloat = NSStatusBar.system.thickness
    ) -> NSImage {
        let (top, bottom) = stackedLines(entry, glyph: glyph)
        let (labelFont, valueFont) = stackedFonts(for: height)

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
        let textWidth = max(labelWidth, valueWidth)
        let width = stackedHorizontalPadding * 2 + symbolSize.width
            + (symbolSize.width > 0 && textWidth > 0 ? stackedSymbolGap : 0) + textWidth

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
                label.draw(at: NSPoint(x: x, y: capTop - capInset(of: labelFont)))
                capTop += labelInk + gap
            }
            if !bottom.isEmpty {
                value.draw(at: NSPoint(x: x, y: capTop - capInset(of: valueFont)))
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
        if entry.style == .stacked {
            return stackedImage(entry, symbol: symbol, glyph: glyph, height: height)
        }

        let text = NSAttributedString(
            string: MenuBarPolicy.stripCell(entry, glyph: glyph),
            attributes: [
                .font: stripFont,
                .foregroundColor: (entry.tint.map(nsColor(for:)) ?? .black)
                    .withAlphaComponent(entry.isStale ? staleOpacity : 1),
            ]
        )
        let textSize = text.size()
        let side = min(height - 4, 16)
        let symbolSize: NSSize = symbol == nil ? .zero : NSSize(width: side, height: side)
        let gap = (symbolSize.width > 0 && textSize.width > 0) ? stackedSymbolGap : 0
        let width = stackedHorizontalPadding * 2 + symbolSize.width + gap + textSize.width

        let image = NSImage(size: NSSize(width: max(width, 1), height: height), flipped: true) { _ in
            var x = stackedHorizontalPadding
            if let symbol {
                symbol.draw(in: NSRect(
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
