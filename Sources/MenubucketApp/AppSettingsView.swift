import AppKit
import MenubucketCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppSettingsWindowController {
    static let shared = AppSettingsWindowController()

    private var window: NSWindow?

    func show(runtime: WidgetRuntime, appPrefs: AppPrefs = .shared) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BarShelf Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.contentView = NSHostingView(
            rootView: AppSettingsView(appPrefs: appPrefs, runtime: runtime)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct AppSettingsView: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var runtime: WidgetRuntime

    @State private var launchError: String?

    private let symbolPresets = [
        "tray.full", "square.grid.2x2", "menubar.rectangle",
        "switch.2", "bolt", "gauge", "sparkles", "circle.grid.3x3",
        "rectangle.stack", "app", "command", "terminal",
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Text("General") }
            performanceTab
                .tabItem { Text("Performance") }
            monitoringTab
                .tabItem { Text("Monitoring") }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
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

            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let error = appPrefs.lastError {
                Text(error)
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

                    Text(row.status)
                        .font(.caption)
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
            case .some(true): status = "OK"
            case .some(false): status = "Failed"
            case .none: status = "No data"
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
