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
    static let maximumHeight: CGFloat = 480

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
        .overlay { ToastOverlay() }
    }
}

private struct MenuBarCardFrame: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime
    @ObservedObject var model: WidgetCardModel
    @ObservedObject var history: ReadingHistory
    let switchesWithArrows: Bool

    private var snapshot: WidgetSnapshot { model.snapshot }

    /// Older than three refreshes (at least a minute): the reading is shown,
    /// dimmed, with its age, instead of passing for current.
    private var isStale: Bool {
        guard let updatedAt = snapshot.updatedAt, model.overlay == nil else { return false }
        let interval = Double(widget.manifest.refresh?.interval ?? 60)
        return Date().timeIntervalSince(updatedAt) > max(60, interval * 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            if model.overlay == nil, snapshot.error == nil, let hero = MenuBarCardHero.Content(
                widget: widget, snapshot: snapshot, history: history.values[widget.id] ?? []
            ) {
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
            if let action = snapshot.viewTree?.action, let title = PrimaryActionTitle.title(for: action) {
                Button {
                    ActionRouter.perform(action, widgetID: widget.id, runtime: runtime)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.icon)
                .hoverHint(LocalizedStringKey(title))
                .accessibilityLabel(title)
            }
            Button { runtime.refresh(widgetID: widget.id) } label: {
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

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Spacing.xs) {
            if isStale {
                Label("Not updated recently", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(StatusTone.warning.color)
            }
            Spacer(minLength: 0)
            if switchesWithArrows {
                ShortcutLabel("Other widgets", key: "← →")
            }
            ShortcutLabel("Close", key: "esc")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
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
    }

    let content: Content

    /// Colour only when the reading asks for attention; a reading in the
    /// normal range stays neutral, as everywhere else.
    private var color: Color {
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
        .accessibilityLabel(Text(verbatim: "\(content.label) \(content.value)"))
    }
}
