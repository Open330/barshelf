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

    @State private var settingsSheetWidget: LoadedWidget?
    @State private var removalTarget: LoadedWidget?
    @State private var newBucketTarget: LoadedWidget?
    @State private var newBucketName = ""
    @State private var widgetActionError: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Text("General") }
            widgetsTab
                .tabItem { Text("Widgets") }
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

    // MARK: - Widgets tab

    private var widgetsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Widgets")
                    .font(.headline)
                Spacer()
                Text("\(runtime.widgets.count) total")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if runtime.widgets.isEmpty {
                Text("No widgets installed yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(widgetRows) { widget in
                    widgetRow(widget)
                        .padding(.vertical, 3)
                }
            }
        }
        .padding(.top, 8)
        .sheet(item: $settingsSheetWidget) { widget in
            WidgetSettingsView(widget: widget, runtime: runtime)
        }
        .alert(
            "Remove Widget?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            presenting: removalTarget
        ) { widget in
            Button("Remove", role: .destructive) { performRemoval(widget) }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { widget in
            Text("This permanently deletes \"\(widget.manifest.name)\" and all of its data. This cannot be undone.")
        }
        .alert(
            "New Bucket",
            isPresented: Binding(
                get: { newBucketTarget != nil },
                set: { if !$0 { newBucketTarget = nil } }
            ),
            presenting: newBucketTarget
        ) { widget in
            TextField("Bucket name", text: $newBucketName)
            Button("Move") {
                let name = newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { runtime.moveWidget(id: widget.id, toGroup: name) }
                newBucketName = ""
                newBucketTarget = nil
            }
            Button("Cancel", role: .cancel) {
                newBucketName = ""
                newBucketTarget = nil
            }
        } message: { _ in
            Text("Move this widget to a new bucket.")
        }
        .alert(
            "Could Not Remove Widget",
            isPresented: Binding(
                get: { widgetActionError != nil },
                set: { if !$0 { widgetActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { widgetActionError = nil }
        } message: {
            Text(widgetActionError ?? "")
        }
    }

    @ViewBuilder
    private func widgetRow(_ widget: LoadedWidget) -> some View {
        let disabled = runtime.prefs.isDisabled(widget.id)
        let group = runtime.effectiveGroup(for: widget.id)
        HStack(spacing: 10) {
            Image(systemName: widget.manifest.icon ?? "square.grid.2x2")
                .frame(width: 20)
                .foregroundColor(disabled ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(widget.manifest.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(disabled ? .secondary : .primary)
                Text(widget.id)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 130, alignment: .leading)

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !runtime.prefs.isDisabled(widget.id) },
                set: { runtime.setWidgetDisabled(widget.id, !$0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(disabled ? "Enable widget" : "Disable widget")
            .accessibilityLabel("\(disabled ? "Enable" : "Disable") \(widget.manifest.name)")

            Menu {
                ForEach(bucketOptions(current: group), id: \.self) { option in
                    Button {
                        runtime.moveWidget(id: widget.id, toGroup: option)
                    } label: {
                        if option == group {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
                Divider()
                Button("New Bucket…") {
                    newBucketName = ""
                    newBucketTarget = widget
                }
            } label: {
                Text(group)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
            .help("Move to bucket")
            .accessibilityLabel("Bucket for \(widget.manifest.name)")

            HStack(spacing: 2) {
                Button {
                    reorder(widget, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(isFirstInGroup(widget))
                .accessibilityLabel("Move \(widget.manifest.name) up")
                Button {
                    reorder(widget, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(isLastInGroup(widget))
                .accessibilityLabel("Move \(widget.manifest.name) down")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button {
                settingsSheetWidget = widget
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            .accessibilityLabel("Settings for \(widget.manifest.name)")

            Button {
                revealInFinder(widget)
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(widget.manifest.name) in Finder")

            Button(role: .destructive) {
                removalTarget = widget
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove…")
            .accessibilityLabel("Remove \(widget.manifest.name)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// All widgets sorted by effective bucket, then override order, then name —
    /// includes disabled widgets (which never appear in `runtime.pages`).
    private var widgetRows: [LoadedWidget] {
        runtime.widgets.sorted { lhs, rhs in
            let lg = runtime.effectiveGroup(for: lhs.id)
            let rg = runtime.effectiveGroup(for: rhs.id)
            if lg != rg {
                return lg.localizedCaseInsensitiveCompare(rg) == .orderedAscending
            }
            let lo = orderValue(lhs)
            let ro = orderValue(rhs)
            if lo != ro { return lo < ro }
            return lhs.manifest.name.localizedCaseInsensitiveCompare(rhs.manifest.name)
                == .orderedAscending
        }
    }

    private func orderValue(_ widget: LoadedWidget) -> Double {
        runtime.prefs.override(for: widget.id)?.order ?? Double(widget.order)
    }

    private func bucketOptions(current: String) -> [String] {
        var options = Set(runtime.allGroups)
        options.insert(current)
        return options.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func groupPeers(_ widget: LoadedWidget) -> [LoadedWidget] {
        let group = runtime.effectiveGroup(for: widget.id)
        return widgetRows.filter { runtime.effectiveGroup(for: $0.id) == group }
    }

    private func isFirstInGroup(_ widget: LoadedWidget) -> Bool {
        groupPeers(widget).first?.id == widget.id
    }

    private func isLastInGroup(_ widget: LoadedWidget) -> Bool {
        groupPeers(widget).last?.id == widget.id
    }

    /// Swaps a widget with its neighbor inside the same bucket and rewrites the
    /// group's order overrides so the new arrangement persists.
    private func reorder(_ widget: LoadedWidget, by delta: Int) {
        var peers = groupPeers(widget)
        guard let index = peers.firstIndex(where: { $0.id == widget.id }) else { return }
        let target = index + delta
        guard target >= 0, target < peers.count else { return }
        peers.swapAt(index, target)
        for (position, peer) in peers.enumerated() {
            runtime.prefs.setOverride(
                group: runtime.prefs.override(for: peer.id)?.group,
                order: Double(position),
                for: peer.id
            )
        }
        runtime.objectWillChange.send()
    }

    private func revealInFinder(_ widget: LoadedWidget) {
        guard let url = runtime.widgetDirectory(for: widget.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func performRemoval(_ widget: LoadedWidget) {
        removalTarget = nil
        do {
            try runtime.removeWidget(id: widget.id)
        } catch {
            widgetActionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
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
