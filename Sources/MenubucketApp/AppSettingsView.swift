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
/// segmented sub-picker (the R11 "Widgets" tab moved to `HubWidgetsView`).
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
        "tray.full", "square.grid.2x2", "menubar.rectangle",
        "switch.2", "bolt", "gauge", "sparkles", "circle.grid.3x3",
        "rectangle.stack", "app", "command", "terminal",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Settings section")
            .frame(maxWidth: 360)

            switch section {
            case .general: generalTab
            case .performance: performanceTab
            case .monitoring: monitoringTab
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: syncLaunchAtLoginStatus)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Menu Bar Icon")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(42)), count: 6), spacing: 8) {
                ForEach(symbolPresets, id: \.self) { symbol in
                    Button {
                        appPrefs.update { $0.menuBarSymbol = symbol }
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 34, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(symbol == appPrefs.preferences.menuBarSymbol
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(symbol)
                    .accessibilityLabel("Menu bar icon \(symbol)")
                    .accessibilityAddTraits(
                        symbol == appPrefs.preferences.menuBarSymbol ? [.isSelected] : []
                    )
                }
            }

            HStack {
                Text("Custom Symbol")
                TextField("SF Symbol", text: Binding(
                    get: { appPrefs.preferences.menuBarSymbol },
                    set: { value in appPrefs.update { $0.menuBarSymbol = value } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { appPrefs.preferences.launchAtLogin },
                set: setLaunchAtLogin
            ))

            Divider()

            Text("Open Popup Hotkey")
                .font(.headline)
            Toggle("Toggle the popup with a global shortcut", isOn: Binding(
                get: { appPrefs.preferences.popupHotkeyEnabled },
                set: { value in appPrefs.update { $0.popupHotkeyEnabled = value } }
            ))
            HStack {
                Text("Shortcut")
                TextField("cmd+shift+b", text: Binding(
                    get: { appPrefs.preferences.popupHotkey },
                    set: { value in appPrefs.update { $0.popupHotkey = value } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .disabled(!appPrefs.preferences.popupHotkeyEnabled)
            }
            Text("e.g. cmd+shift+b")
                .font(.caption)
                .foregroundColor(.secondary)

            if let launchError {
                Label(launchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let error = appPrefs.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var performanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Refresh")
                .font(.headline)
            Picker("Refresh Multiplier", selection: Binding(
                get: { appPrefs.preferences.refreshMultiplier },
                set: { value in
                    appPrefs.update { $0.refreshMultiplier = value }
                }
            )) {
                Text("0.5x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
                Text("4x").tag(4.0)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Toggle("Pause all refreshes while the popup is closed", isOn: Binding(
                get: { appPrefs.preferences.pauseWhenClosed },
                set: { value in appPrefs.update { $0.pauseWhenClosed = value } }
            ))

            Spacer()
        }
        .padding(.top, 8)
    }

    private var monitoringTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Refresh Statistics")
                    .font(.headline)
                Spacer()
                Button("Open Logs Folder", action: openLogsFolder)
            }

            List(monitoringRows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(row.id)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(minWidth: 160, alignment: .leading)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(row.statusColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(row.status)
                            .font(.caption)
                    }
                    .frame(width: 70, alignment: .leading)

                    Text("S \(row.successCount) / F \(row.failureCount)")
                        .font(.caption)
                        .frame(width: 86, alignment: .leading)

                    Text(row.averageDuration)
                        .font(.caption)
                        .frame(width: 82, alignment: .leading)

                    Text(row.lastDuration)
                        .font(.caption)
                        .frame(width: 82, alignment: .leading)

                    Text(row.lastRefresh)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.top, 8)
    }

    private var monitoringRows: [MonitoringRow] {
        runtime.widgets.map { widget in
            MonitoringRow(widget: widget, stats: runtime.refreshStatsSnapshot[widget.id])
        }
    }

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
            name = widget.manifest.name
            successCount = stats?.successCount ?? 0
            failureCount = stats?.failureCount ?? 0
            averageDuration = Self.ms(stats?.averageDurationMs, prefix: "avg")
            lastDuration = Self.ms(stats?.lastDurationMs, prefix: "last")
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
            guard let value else { return "\(prefix) -" }
            return "\(prefix) \(Int(value.rounded())) ms"
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter
        }()
    }
}
