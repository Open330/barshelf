import Foundation

/// Everything one widget's menu bar entry is built from, spelled out so the
/// menu bar, the settings preview and the landing media build it the same
/// way.
public struct MenuBarEntryInputs {
    public var widgetID: String
    /// The widget's display name.
    public var name: String
    /// `manifest.icon`: the last icon tried.
    public var manifestIcon: String?
    /// The manifest's status item as written. The builder resolves it
    /// through `effectiveStatusItem`; callers do not.
    public var statusItem: Manifest.StatusItem?
    /// The stored placement, or the draft a settings pane is editing.
    public var placement: MenuBarPlacement
    /// The app-wide menu bar style.
    public var globalPresentation: MenuBarPresentation?
    public var snapshot: WidgetSnapshot?
    /// Whether the reading is out of date: the caller knows the cadence.
    public var isStale: Bool
    /// The tooltip as the caller resolved it (a failure's explanation, or
    /// the widget's own).
    public var tooltip: String?
    /// Text that stands in for a label the widget has not produced yet.
    /// Only a preview has one; the menu bar draws nothing.
    public var placeholderLabel: String?
    /// Whether a name is an SF Symbol. Core cannot ask AppKit, so the app
    /// passes the answer in.
    public var isSymbolName: (String) -> Bool

    public init(
        widgetID: String,
        name: String,
        manifestIcon: String? = nil,
        statusItem: Manifest.StatusItem? = nil,
        placement: MenuBarPlacement,
        globalPresentation: MenuBarPresentation? = nil,
        snapshot: WidgetSnapshot? = nil,
        isStale: Bool = false,
        tooltip: String? = nil,
        placeholderLabel: String? = nil,
        isSymbolName: @escaping (String) -> Bool
    ) {
        self.widgetID = widgetID
        self.name = name
        self.manifestIcon = manifestIcon
        self.statusItem = statusItem
        self.placement = placement
        self.globalPresentation = globalPresentation
        self.snapshot = snapshot
        self.isStale = isStale
        self.tooltip = tooltip
        self.placeholderLabel = placeholderLabel
        self.isSymbolName = isSymbolName
    }
}

/// Where a widget's cell goes and how it is laid out: the part of an entry
/// that depends on the manifest and the placement alone, not on a reading.
public struct MenuBarEntryLayout: Equatable, Sendable {
    public var style: MenuBarStyle
    /// The widget has text to put in the shared strip: a label, or an emoji
    /// the user gave it. Whether it does share is `separate`.
    public var canShareStrip: Bool
    /// The widget takes a status item of its own.
    public var separate: Bool

    public init(style: MenuBarStyle, canShareStrip: Bool, separate: Bool) {
        self.style = style
        self.canShareStrip = canShareStrip
        self.separate = separate
    }
}

/// A built entry and what the caller still has to decide from it.
public struct BuiltMenuBarEntry: Equatable, Sendable {
    /// Presentation applied; no chart history yet.
    public var entry: MenuBarEntry
    public var separate: Bool
    /// The item draws a chart, so its caller supplies the history.
    public var wantsChart: Bool

    public init(entry: MenuBarEntry, separate: Bool, wantsChart: Bool) {
        self.entry = entry
        self.separate = separate
        self.wantsChart = wantsChart
    }
}

extension MenuBarPolicy {
    public static func entryLayout(
        statusItem rawStatusItem: Manifest.StatusItem?,
        placement: MenuBarPlacement,
        isSymbolName: (String) -> Bool
    ) -> MenuBarEntryLayout {
        let statusItem = effectiveStatusItem(rawStatusItem)
        // Only text can share the strip, so a widget that shows no label
        // gets its own item — unless the user gave it an emoji, which is
        // text and so can sit in the strip like any other.
        let hasTextIcon = normalizedIcon(placement.icon)
            .map { !$0.isEmpty && !isSymbolName($0) }
            ?? false
        // Two rows cannot be drawn into a shared run of text, so the
        // stacked style takes its own item the way an icon-only widget does.
        let style = resolvedStyle(
            user: placement.style, manifest: statusItem.style
        )
        let canShareStrip = statusItem.showsLabel || hasTextIcon
        let separate = placement.separate
            || style == .stacked
            || style == .metrics
            || !canShareStrip
        return MenuBarEntryLayout(style: style, canShareStrip: canShareStrip, separate: separate)
    }

    /// The entry the menu bar draws for one widget, with its presentation
    /// applied. A chart's history is the caller's to add.
    public static func buildEntry(_ inputs: MenuBarEntryInputs) -> BuiltMenuBarEntry {
        let statusItem = effectiveStatusItem(inputs.statusItem)
        let snapshot = inputs.snapshot
        let placement = inputs.placement
        let layout = entryLayout(
            statusItem: inputs.statusItem, placement: placement, isSymbolName: inputs.isSymbolName
        )
        let presentation = resolvedPresentation(
            user: placement.presentation,
            global: inputs.globalPresentation,
            live: snapshot?.statusPresentation,
            manifest: statusItem.presentation
        )
        var entry = MenuBarEntry(
            widgetID: inputs.widgetID,
            name: inputs.name,
            symbol: statusItem.showsIcon
                ? resolvedIcon(
                    user: nil,
                    live: snapshot?.statusIcon,
                    statusItem: statusItem.icon,
                    manifest: inputs.manifestIcon
                )
                : nil,
            iconOverride: normalizedIcon(placement.icon),
            prefix: resolvedPrefix(
                user: placement.label,
                live: snapshot?.statusPrefix,
                manifest: statusItem.label
            ),
            style: layout.style,
            tint: MenuBarTint.named(snapshot?.statusTint),
            // A widget that has never run has nothing to show; a preview
            // stands in rather than rendering an empty box.
            label: statusItem.showsLabel
                ? (normalizedLabel(snapshot?.statusLabel) ?? inputs.placeholderLabel) : nil,
            metrics: statusItem.showsLabel
                ? normalizedMetrics(snapshot?.statusMetrics ?? []) : [],
            tooltip: inputs.tooltip,
            isStale: inputs.isStale,
            separate: layout.separate,
            presentation: presentation
        )
        entry.iconSymbol = resolvedIcon(
            user: nil, live: snapshot?.statusIcon, statusItem: statusItem.icon, manifest: inputs.manifestIcon
        )
        entry.profiles = statusItem.profiles ?? false
        if entry.profiles, statusItem.showsLabel {
            entry.profileMetrics = normalizedMetrics(
                snapshot?.statusMetrics ?? [], limit: MenuBarClusterPolicy.maxChips
            )
        }
        return BuiltMenuBarEntry(
            entry: applyingPresentation(presentation, to: entry),
            separate: layout.separate,
            // Only an item with its own place draws a chart; the strip is
            // text, and history there would only make it redraw.
            wantsChart: presentation.effectiveChart != .none && layout.separate
        )
    }
}
