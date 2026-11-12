import AppKit
import MenubucketCore
import SwiftUI

/// One widget's card, shown from its own menu bar item or a cluster chip.
///
/// Every widget gets the same frame here, whatever it draws: a header with
/// its mark, name and freshness, the controls (its own "open" action made
/// visible, refresh, settings), the reading it shows in the menu bar large
/// beside its recent trend, then the widget's own content, and the keys at
/// the bottom. The content is the same `WidgetCardView` the shelf draws, so
/// nothing has to be maintained twice.
struct MenuBarWidgetPopover: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime
    /// ← → move to the neighbouring chip (cluster layout only).
    var switchesWithArrows = false

    /// Room for two-column rows without reading as a window.
    static let width: CGFloat = 330
    /// Past this the content scrolls rather than growing off the screen.
    static let maximumHeight: CGFloat = 560

    var body: some View {
        MenuBarCardFrame(
            widget: widget,
            runtime: runtime,
            model: runtime.cardModel(for: widget.id),
            history: runtime.readingHistory,
            switchesWithArrows: switchesWithArrows
        )
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
        .overlay { ToastOverlay(surface: .menuBarCard) }
        .environment(\.toastSurface, .menuBarCard)
    }
}

private struct MenuBarCardFrame: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime
    @ObservedObject var model: WidgetCardModel
    @ObservedObject var history: ReadingHistory
    let switchesWithArrows: Bool

    private var snapshot: WidgetSnapshot { model.snapshot }

    /// Past the same threshold that dims the menu bar item it opened from
    /// (`WidgetRuntime.readingIsStale`): the reading is shown, dimmed, with
    /// its age, instead of passing for current. A card with nothing loaded
    /// yet, or showing a permission card, has no reading to dim.
    private var isStale: Bool {
        guard snapshot.updatedAt != nil, model.overlay == nil else { return false }
        return runtime.readingIsStale(widget, updatedAt: snapshot.updatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            if model.overlay == nil, snapshot.error == nil, let hero = MenuBarCardHero.Content(
                widget: widget, snapshot: snapshot, history: history.values[widget.id] ?? []
            ) ?? MenuBarCardHero.Content.placeholder(widget: widget, snapshot: snapshot) {
                MenuBarCardHero(content: hero)
                    .opacity(isStale ? Fill.staleOpacity : 1)
            }
            // As tall as the content; a scroll view only when the content
            // does not fit, since a scroll view always takes all the height
            // it is offered and would hold the card at its maximum.
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical) { content }
            }
            footer
        }
        .padding(Spacing.s)
    }

    private var content: some View {
        WidgetCardView(widget: widget, runtime: runtime, placement: .menuBar)
            .opacity(isStale ? Fill.staleOpacity : 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            WidgetMark(widget: widget, runtime: runtime, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(widget.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let updatedAt = snapshot.updatedAt, model.overlay == nil {
                    FreshnessText(updatedAt: updatedAt)
                }
            }
            Spacer(minLength: Spacing.xxs)
            if snapshot.isLoading, snapshot.viewTree != nil {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            }
            Button { runtime.requestRefresh(widgetID: widget.id, feedbackOn: .menuBarCard) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.icon)
            .hoverHint("Refresh", key: "⌘R")
            .accessibilityLabel("Refresh \(widget.displayName)")
            Button {
                let id = widget.id
                Task { @MainActor in HubWindowController.shared.showWidgetSettings(widgetID: id) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.icon)
            .hoverHint("Settings…", key: "⌘,")
            .accessibilityLabel("Settings for \(widget.displayName)")
        }
    }

    // MARK: Footer

    /// The whole row is tried with the action named, then with its icon
    /// alone: each at its natural width, so the name shows whenever the row
    /// has room for it beside the hints.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerRow(namesAction: true)
            footerRow(namesAction: false)
        }
    }

    private func footerRow(namesAction: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            // A button of its own, outside the combined hint element below.
            primaryAction(named: namesAction)
            HStack(spacing: Spacing.xs) {
                if isStale {
                    Label("Not updated recently", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(StatusTone.warning.color)
                }
                Spacer(minLength: 0)
                // Key hints, not buttons: a key cap, then what it does.
                if switchesWithArrows {
                    keyHint("Other widgets", key: "← →")
                }
                keyHint("Close", key: "esc")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    /// The widget's whole-card action, by name — "Open Activity Monitor" —
    /// or its icon alone.
    @ViewBuilder
    private func primaryAction(named: Bool) -> some View {
        if let action = snapshot.viewTree?.action, let title = PrimaryActionTitle.title(for: action) {
            let perform = {
                ActionRouter.perform(action, widgetID: widget.id, runtime: runtime, title: title, surface: .menuBarCard)
            }
            if named {
                Button(action: perform) {
                    Label(title, systemImage: "arrow.up.forward.app")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glass(.secondary))
                .controlSize(.small)
                .fixedSize()
            } else {
                Button(action: perform) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.icon)
                .hoverHint(LocalizedStringKey(title))
                .accessibilityLabel(title)
            }
        }
    }

    private func keyHint(_ title: LocalizedStringKey, key: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            KeyCap(key)
            Text(title)
        }
    }
}

/// What a widget's whole-card action does, in words, for the button that
/// makes it visible. Nil hides the button: an action without a clear name
/// stays on the card alone.
enum PrimaryActionTitle {
    static func title(for action: NodeAction) -> String? {
        switch action.type {
        case "openApp":
            guard let value = action.value ?? action.url else { return nil }
            return String(localized: "Open \(appName(value))", comment: "Button: open the app a widget belongs to")
        case "openURL":
            return String(localized: "Open in Browser")
        case "openFile":
            return String(localized: "Open", comment: "Button: open the file a widget shows")
        case "revealFile":
            return String(localized: "Show in Finder")
        default:
            return nil
        }
    }

    /// A bundle id or .app path as the app's name; a name stays as it is.
    static func appName(_ value: String) -> String {
        if value.hasSuffix(".app") {
            return FileManager.default.displayName(atPath: value).replacingOccurrences(of: ".app", with: "")
        }
        if value.contains("."), !value.contains(" "),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return value
    }
}

/// The widget's menu bar reading, large, with its label and recent trend —
/// the reason the card was opened, first.
struct MenuBarCardHero: View {
    struct Content: Equatable {
        let label: String
        let value: String
        let tint: String?
        let history: [Double]
        let isPercent: Bool
        /// Holding the place of a reading that has not arrived yet.
        var isPlaceholder = false

        /// Nil when the widget has nothing for the menu bar, or opted out.
        init?(widget: LoadedWidget, snapshot: WidgetSnapshot, history: [Double]) {
            guard widget.manifest.statusItem?.popoverHero != false else { return nil }
            if let metric = snapshot.statusMetrics?.first(where: { !$0.value.isEmpty }) {
                label = metric.label
                value = metric.value
                tint = metric.tint ?? snapshot.statusTint
                isPercent = metric.format == "percent" || metric.value.hasSuffix("%")
            } else if let text = snapshot.statusLabel, !text.isEmpty {
                label = snapshot.statusPrefix ?? ""
                value = text
                tint = snapshot.statusTint
                isPercent = text.hasSuffix("%")
            } else {
                return nil
            }
            self.history = history
        }

        private init(label: String, value: String) {
            self.label = label
            self.value = value
            tint = nil
            history = []
            isPercent = false
            isPlaceholder = true
        }

        /// "—" and the reading's name, while a widget that shows a reading
        /// has none yet (loading, nothing yet): the card keeps its height
        /// instead of jumping when the number arrives.
        static func placeholder(widget: LoadedWidget, snapshot: WidgetSnapshot) -> Content? {
            // Only before the first reading, or while one is on its way; a
            // widget that has refreshed and shows nothing gets no hero.
            guard snapshot.updatedAt == nil || snapshot.isLoading,
                  let statusItem = widget.manifest.statusItem, statusItem.isPromotable,
                  statusItem.popoverHero != false else { return nil }
            let label = snapshot.statusPrefix
                ?? statusItem.label.map { widget.manifest.localization()?.text($0) ?? $0 }
                ?? ""
            return Content(label: label, value: "—")
        }
    }

    let content: Content

    /// Colour only when the reading asks for attention; a reading in the
    /// normal range stays neutral, as everywhere else.
    private var color: Color {
        if content.isPlaceholder { return .secondary }
        switch content.tint {
        case "warning": return StatusTone.warning.color
        case "danger", "critical", "error": return StatusTone.critical.color
        default: return .primary
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(content.value)
                    .font(Typography.metric(.regular))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !content.label.isEmpty {
                    Text(content.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            if content.history.count > 2 {
                TrendLine(values: content.history, tint: color, ceiling: content.isPercent ? 100 : nil,
                          height: Spacing.xl + Spacing.s)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.cardInset)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Fill.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.isPlaceholder
            ? Text("\(content.label) no reading yet", comment: "VoiceOver: a card's big reading before it has one")
            : Text(verbatim: "\(content.label) \(content.value)"))
    }
}
