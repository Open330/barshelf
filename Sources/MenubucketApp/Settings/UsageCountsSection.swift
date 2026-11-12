import MenubucketCore
import SwiftUI

/// Settings ▸ Privacy: what BarShelf counted about its own use, on this Mac.
///
/// Evidence for the owner, not telemetry: which widgets get opened and
/// pressed, and which have sat untouched for a month.
struct UsageCountsSection: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var appPrefs: AppPrefs
    @State private var summary: UsageSummary?
    @State private var confirmingClear = false
    @State private var showingAll = false

    static let windowDays = 30
    /// Rows shown before "Show All".
    static let shortList = 8

    var body: some View {
        let enabled = appPrefs.preferences.usageCountsEnabled
        Section {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { value in appPrefs.update { $0.usageCountsEnabled = value } }
            )) {
                Text("Count how I use BarShelf")
                Text("How often the shelf opens and each widget is seen, pressed or opened from the menu bar. Kept on this Mac only, for 90 days, and never sent anywhere.")
            }
            .accessibilityLabel("Count how I use BarShelf")

            if let summary {
                content(summary)
            }
        } header: {
            Text("Usage on This Mac")
                .settingsSectionTitle()
        } footer: {
            Text("Nothing a widget shows is recorded, only that it was opened or pressed. The terminal command barshelf usage prints the same list.")
                .formFooter()
        }
        .onAppear(perform: reload)
        .onChange(of: runtime.widgets.map(\.id)) { _, _ in reload() }
        .confirmationDialog("Clear usage counts?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Counts", role: .destructive) {
                runtime.usageStore.clear()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count on this Mac is removed. Counting starts again from now unless you turn it off.")
        }
    }

    @ViewBuilder
    private func content(_ summary: UsageSummary) -> some View {
        let rows = summary.rows.filter(\.installed)
        let used = rows.filter { !$0.neverUsed }
        let idle = rows.filter(\.neverUsed)
        if summary.popupOpens == 0 && used.isEmpty {
            Text(appPrefs.preferences.usageCountsEnabled
                 ? String(localized: "Nothing counted yet. Open the shelf and use a widget, and it shows up here.", comment: "Privacy usage: empty state")
                 : String(localized: "Counting is off.", comment: "Privacy usage: empty state while turned off"))
                .foregroundStyle(.secondary)
        } else {
            LabeledContent {
                Text(verbatim: "\(summary.popupOpens)")
                    .monospacedDigit()
            } label: {
                Text("Shelf opened")
                Text(Self.windowLine(summary))
            }
            let shown = showingAll ? used : Array(used.prefix(Self.shortList))
            ForEach(shown, id: \.widgetID) { row in
                UsageRowView(name: name(of: row.widgetID), usage: row.usage)
            }
            if used.count > Self.shortList {
                Button(showingAll
                       ? String(localized: "Show Fewer", comment: "Privacy usage: collapse the widget list")
                       : String(localized: "Show All \(used.count)", comment: "Privacy usage: expand the widget list")) {
                    showingAll.toggle()
                }
                .buttonStyle(.link)
            }
        }
        if !idle.isEmpty, summary.activeDays > 0 {
            LabeledContent {
                EmptyView()
            } label: {
                Label {
                    Text(Self.idleTitle(idle.count, summary: summary))
                } icon: {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                }
                Text(idle.map { name(of: $0.widgetID) }.joined(separator: ", "))
            }
        }
        if summary.popupOpens > 0 || !used.isEmpty {
            HStack {
                Spacer()
                Button("Clear Counts…") { confirmingClear = true }
                    .buttonStyle(.glass(.secondary))
                    .controlSize(.small)
            }
        }
    }

    private func reload() {
        runtime.usageStore.flush()
        summary = runtime.usageStore.summary(days: Self.windowDays, known: runtime.widgets.map(\.id))
    }

    private func name(of widgetID: String) -> String {
        runtime.widgets.first { $0.id == widgetID }?.displayName ?? widgetID
    }

    static func windowLine(_ summary: UsageSummary) -> String {
        let from = UsageDay.date(summary.from, calendar: .current)
            .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? summary.from
        return summary.activeDays == 1
            ? String(localized: "Since \(from), 1 day with use", comment: "Privacy usage: the period covered, when one day had any use")
            : String(localized: "Since \(from), \(summary.activeDays) days with use", comment: "Privacy usage: the period covered and how many days had any use")
    }

    /// The day counting began, when that is inside the window: the counts
    /// then say "since" that day, not "in 30 days".
    static func countingSince(_ summary: UsageSummary) -> String? {
        guard !summary.coversWholeWindow(calendar: .current) else { return nil }
        return UsageDay.date(summary.from, calendar: .current)
            .map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? summary.from
    }

    static func idleTitle(_ count: Int, summary: UsageSummary) -> String {
        if let since = countingSince(summary) {
            return count == 1
                ? String(localized: "1 widget not used since \(since)", comment: "Privacy usage: widgets never seen or used since counting began")
                : String(localized: "\(count) widgets not used since \(since)", comment: "Privacy usage: widgets never seen or used since counting began")
        }
        return count == 1
            ? String(localized: "1 widget not used in \(summary.days) days", comment: "Privacy usage: widgets never seen or used in the window")
            : String(localized: "\(count) widgets not used in \(summary.days) days", comment: "Privacy usage: widgets never seen or used in the window")
    }

    /// The label under the page's "not used" figure.
    static func idleStatLabel(_ summary: UsageSummary) -> String {
        if let since = countingSince(summary) {
            return String(localized: "Not used since \(since)", comment: "Privacy summary: installed widgets with no use since counting began")
        }
        return String(localized: "Not used in \(summary.days) days", comment: "Privacy summary: installed widgets with no use in the window")
    }
}

private struct UsageRowView: View {
    let name: String
    let usage: WidgetUsage

    var body: some View {
        LabeledContent {
            Text(verbatim: "\(usage.interactions)")
                .monospacedDigit()
                .foregroundStyle(usage.interactions == 0 ? .secondary : .primary)
        } label: {
            Text(verbatim: name)
            Text(Self.detail(usage))
        }
        .accessibilityElement(children: .combine)
    }

    static func detail(_ usage: WidgetUsage) -> String {
        var parts: [String] = []
        if usage.views > 0 { parts.append(String(localized: "seen \(usage.views)×", comment: "Privacy usage: times a widget was on the open shelf")) }
        if usage.actions > 0 { parts.append(String(localized: "pressed \(usage.actions)×", comment: "Privacy usage: actions run from a widget")) }
        let menuBar = usage.menuBarClicks + usage.menuBarCardOpens
        if menuBar > 0 { parts.append(String(localized: "menu bar \(menuBar)×", comment: "Privacy usage: clicks and card opens from the menu bar")) }
        if usage.interactions == 0 { parts.append(String(localized: "only seen", comment: "Privacy usage: seen on the shelf but never pressed")) }
        return parts.joined(separator: " · ")
    }
}
