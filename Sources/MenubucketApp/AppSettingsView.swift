import AppKit
import MenubucketCore
import ServiceManagement
import SwiftUI

/// Back-compat shim: the standalone settings window is gone — settings now live
/// in the hub's Settings section. Keeps the historical signature so callers
/// (RootView footer, status item menu) need no edits.
@MainActor
final class AppSettingsWindowController {
    static let shared = AppSettingsWindowController()

    func show(runtime: WidgetRuntime, appPrefs: AppPrefs = .shared) {
        _ = appPrefs
        HubWindowController.shared.show(runtime: runtime, tab: .settings)
    }
}

/// The hub's Settings section: General / Performance / Monitoring behind a
/// segmented sub-picker, rendered as native grouped `Form`s so the screen reads
/// like a modern macOS System Settings pane.
struct AppSettingsView: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var runtime: WidgetRuntime

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case performance = "Performance"
        case monitoring = "Monitoring"
        var id: String { rawValue }
    }

    @State private var section: Section = .general
    @State private var launchError: String?

    private let symbolPresets = [
        BarShelfStatusIcon.logoSymbol, "tray.full", "square.grid.2x2",
        "menubar.rectangle", "switch.2", "bolt", "gauge", "sparkles",
        "circle.grid.3x3", "rectangle.stack", "app", "terminal",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")
            .frame(maxWidth: 380)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Form {
                switch section {
                case .general: generalSection
                case .performance: performanceSection
                case .monitoring: monitoringSection
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: syncLaunchAtLoginStatus)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        SwiftUI.Section {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6), spacing: 8) {
                ForEach(symbolPresets, id: \.self) { symbol in
                    Button {
                        appPrefs.update { $0.menuBarSymbol = symbol }
                    } label: {
                        menuBarIconPreview(symbol)
                            .frame(width: 40, height: 30)
                            .background(selectionBackground(for: symbol))
                    }
                    .buttonStyle(.plain)
                    .help(symbol == BarShelfStatusIcon.logoSymbol ? "BarShelf logo" : symbol)
                    .accessibilityLabel(
                        "Menu bar icon \(symbol == BarShelfStatusIcon.logoSymbol ? "BarShelf logo" : symbol)"
                    )
                    .accessibilityAddTraits(
                        symbol == appPrefs.preferences.menuBarSymbol ? [.isSelected] : []
                    )
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Menu Bar Icon")
        } footer: {
            Text("Shown in the menu bar. Pick the icon that best fits your setup.")
        }

        SwiftUI.Section {
            Toggle(isOn: Binding(
                get: { appPrefs.preferences.launchAtLogin },
                set: setLaunchAtLogin
            )) {
                Text("Launch at Login")
                Text("Open BarShelf automatically when you sign in.")
            }

            Toggle(isOn: Binding(
                get: { appPrefs.preferences.popupHotkeyEnabled },
                set: { value in appPrefs.update { $0.popupHotkeyEnabled = value } }
            )) {
                Text("Global Shortcut")
                Text("Toggle the popup from anywhere with a keyboard shortcut.")
            }

            if appPrefs.preferences.popupHotkeyEnabled {
                LabeledContent("Shortcut") {
                    TextField("cmd+shift+b", text: Binding(
                        get: { appPrefs.preferences.popupHotkey },
                        set: { value in appPrefs.update { $0.popupHotkey = value } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180)
                }
            }
        } header: {
            Text("General")
        }

        SwiftUI.Section {
            LabeledContent("Version") {
                Text(AppVersionInfo.current.versionLabel)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            if let build = AppVersionInfo.current.build {
                LabeledContent("Build") {
                    Text(build)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }

            Button("Check for Updates…") {
                UpdateChecker.check(explicit: true)
            }
        } header: {
            Text("About BarShelf")
        } footer: {
            Text("Version and build information for this installation.")
        }

        if let launchError {
            SwiftUI.Section {
                Label(launchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        if let error = appPrefs.lastError {
            SwiftUI.Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private func menuBarIconPreview(_ symbol: String) -> some View {
        if symbol == BarShelfStatusIcon.logoSymbol {
            Image(nsImage: BarShelfStatusIcon.logoImage())
                .renderingMode(.template)
                .foregroundStyle(Color.primary)
        } else {
            Image(systemName: symbol)
        }
    }

    private func selectionBackground(for symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(symbol == appPrefs.preferences.menuBarSymbol
                ? Color.accentColor.opacity(0.20)
                : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        symbol == appPrefs.preferences.menuBarSymbol
                            ? Color.accentColor.opacity(0.55) : Color.clear
                    )
            )
    }

    // MARK: - Performance

    @ViewBuilder
    private var performanceSection: some View {
        SwiftUI.Section {
            Picker("Refresh Cadence", selection: Binding(
                get: { appPrefs.preferences.refreshMultiplier },
                set: { value in appPrefs.update { $0.refreshMultiplier = value } }
            )) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("4×").tag(4.0)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: Binding(
                get: { appPrefs.preferences.pauseWhenClosed },
                set: { value in appPrefs.update { $0.pauseWhenClosed = value } }
            )) {
                Text("Pause When Closed")
                Text("Stop refreshing widgets while the popup is hidden.")
            }
        } header: {
            Text("Refresh Policy")
        } footer: {
            Text("Scales every widget's cadence without editing individual manifests.")
        }

        SwiftUI.Section {
            HStack(spacing: 10) {
                statTile("\(runtime.widgets.count)", "widgets")
                statTile("\(runtime.pages.count)", "panels")
                statTile("\(runtime.refreshStatsSnapshot.count)", "tracked")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        } header: {
            Text("Runtime")
        }
    }

    // MARK: - Monitoring

    @ViewBuilder
    private var monitoringSection: some View {
        SwiftUI.Section {
            if monitoringRows.isEmpty {
                Label("No widgets installed yet.", systemImage: "tray")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ForEach(monitoringRows) { row in
                    monitoringRowView(row)
                }
            }
        } header: {
            HStack {
                Text("Refresh Statistics")
                Spacer()
                Button("Open Logs", action: openLogsFolder)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } footer: {
            Text("Recent outcomes and timing per installed widget.")
        }
    }

    private func monitoringRowView(_ row: MonitoringRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(row.id)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(row.statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(row.status)
                    .font(.caption)
            }
            .frame(width: 66, alignment: .leading)

            Text("\(row.successCount)✓ \(row.failureCount)✗")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)

            Text(row.lastDuration)
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 66, alignment: .trailing)

            Text(row.lastRefresh)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var monitoringRows: [MonitoringRow] {
        runtime.widgets.map { widget in
            MonitoringRow(widget: widget, stats: runtime.refreshStatsSnapshot[widget.id])
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appPrefs.update { $0.launchAtLogin = enabled }
            launchError = nil
        } catch {
            launchError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            syncLaunchAtLoginStatus()
        }
    }

    private func syncLaunchAtLoginStatus() {
        appPrefs.update {
            $0.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func openLogsFolder() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BarShelf", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logs, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(logs)
    }

    private struct MonitoringRow: Identifiable {
        let id: String
        let name: String
        let status: String
        let successCount: Int
        let failureCount: Int
        let averageDuration: String
        let lastDuration: String
        let lastRefresh: String
        let statusColor: Color

        init(widget: LoadedWidget, stats: WidgetRefreshStats?) {
            id = widget.id
            name = widget.displayName
            successCount = stats?.successCount ?? 0
            failureCount = stats?.failureCount ?? 0
            averageDuration = Self.ms(stats?.averageDurationMs, prefix: "avg")
            lastDuration = Self.ms(stats?.lastDurationMs, prefix: "")
            if let last = stats?.lastRefreshAt {
                lastRefresh = Self.relativeFormatter.localizedString(
                    for: last, relativeTo: Date()
                )
            } else {
                lastRefresh = "Never"
            }
            switch stats?.lastOutcomeWasSuccess {
            case .some(true): status = "OK"; statusColor = .green
            case .some(false): status = "Failed"; statusColor = .red
            case .none: status = "No data"; statusColor = .gray
            }
        }

        private static func ms(_ value: Double?, prefix: String) -> String {
            guard let value else { return prefix.isEmpty ? "–" : "\(prefix) –" }
            let body = "\(Int(value.rounded())) ms"
            return prefix.isEmpty ? body : "\(prefix) \(body)"
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter
        }()
    }
}
