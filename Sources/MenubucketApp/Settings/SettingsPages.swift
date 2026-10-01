import AppKit
import MenubucketCore
import ServiceManagement
import SwiftUI

/// One settings page: a single grouped form, the way System Settings lays
/// out a pane. No page nests another picker inside it (R13 §4.1).
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A preference write that failed, shown where the user made the change.
private struct PrefsErrorSection: View {
    @ObservedObject var appPrefs: AppPrefs

    var body: some View {
        if let error = appPrefs.lastError {
            Section {
                StatusBanner(tone: .critical, message: String(localized: "Couldn't save settings: \(error)"))
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @State private var launchError: String?

    static let symbolPresets = [
        BarShelfStatusIcon.logoSymbol, "tray.full", "square.grid.2x2",
        "menubar.rectangle", "switch.2", "bolt", "gauge", "sparkles",
        "circle.grid.3x3", "rectangle.stack", "app", "terminal",
    ]

    var body: some View {
        SettingsPage {
            Section {
                Picker("Menu bar icon", selection: Binding(
                    get: { appPrefs.preferences.menuBarSymbol },
                    set: { value in appPrefs.update { $0.menuBarSymbol = value } }
                )) {
                    ForEach(Self.symbolPresets, id: \.self) { symbol in
                        Label {
                            Text(Self.name(for: symbol))
                        } icon: {
                            Self.icon(for: symbol)
                        }
                        .tag(symbol)
                    }
                    if !Self.symbolPresets.contains(appPrefs.preferences.menuBarSymbol) {
                        Text(appPrefs.preferences.menuBarSymbol)
                            .tag(appPrefs.preferences.menuBarSymbol)
                    }
                }
            } footer: {
                Text("The icon BarShelf shows in the menu bar.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.launchAtLogin },
                    set: setLaunchAtLogin
                )) {
                    Text("Open at login")
                    Text("Start BarShelf when you sign in to your Mac.")
                }
                if let launchError {
                    StatusBanner(tone: .critical, message: launchError)
                }

                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.copySoundEnabled },
                    set: { value in appPrefs.update { $0.copySoundEnabled = value } }
                )) {
                    Text("Play a sound when copying")
                    Text("A confirmation always appears; this adds a sound.")
                }
            }

            PrefsErrorSection(appPrefs: appPrefs)
        }
        .onAppear(perform: syncLaunchAtLoginStatus)
    }

    static func name(for symbol: String) -> String {
        switch symbol {
        case BarShelfStatusIcon.logoSymbol: return "BarShelf"
        case "tray.full": return String(localized: "Tray", comment: "Menu bar icon choice")
        case "square.grid.2x2": return String(localized: "Grid", comment: "Menu bar icon choice")
        case "menubar.rectangle": return String(localized: "Menu Bar", comment: "Menu bar icon choice")
        case "switch.2": return String(localized: "Switches", comment: "Menu bar icon choice")
        case "bolt": return String(localized: "Bolt", comment: "Menu bar icon choice")
        case "gauge": return String(localized: "Gauge", comment: "Menu bar icon choice")
        case "sparkles": return String(localized: "Sparkles", comment: "Menu bar icon choice")
        case "circle.grid.3x3": return String(localized: "Dots", comment: "Menu bar icon choice")
        case "rectangle.stack": return String(localized: "Stack", comment: "Menu bar icon choice")
        case "app": return String(localized: "App", comment: "Menu bar icon choice")
        case "terminal": return String(localized: "Terminal", comment: "Menu bar icon choice")
        default: return symbol
        }
    }

    @ViewBuilder
    static func icon(for symbol: String) -> some View {
        if symbol == BarShelfStatusIcon.logoSymbol {
            Image(nsImage: BarShelfStatusIcon.logoImage()).renderingMode(.template)
        } else {
            Image(systemName: symbol)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchError = Self.setLaunchAtLogin(enabled, appPrefs: appPrefs)
        if launchError != nil { syncLaunchAtLoginStatus() }
    }

    /// Registers or unregisters the login item. Returns why it failed, if it did.
    static func setLaunchAtLogin(_ enabled: Bool, appPrefs: AppPrefs) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            appPrefs.update { $0.launchAtLogin = enabled }
            return nil
        } catch {
            return String(localized: "Couldn't change login items: ")
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Mirrors the system's answer, writing only when it differs so opening
    /// the page does not rewrite the preferences file.
    private func syncLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        guard appPrefs.preferences.launchAtLogin != enabled else { return }
        appPrefs.update { $0.launchAtLogin = enabled }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject private var registration = HotkeyRegistrationCoordinator.shared

    var body: some View {
        SettingsPage {
            Section {
                LabeledContent {
                    KeyRecorder(
                        shortcut: appPrefs.preferences.popupHotkeyEnabled
                            ? appPrefs.preferences.popupHotkey : "",
                        onRecord: { registration.enable(draft: $0, appPrefs: appPrefs) },
                        onClear: { registration.disable(appPrefs: appPrefs) }
                    )
                } label: {
                    Text("Open BarShelf")
                    Text("Show or hide the popup from any app.")
                }
                if let message = registration.message {
                    StatusBanner(tone: .warning, message: message)
                }
            } header: {
                Text("Global")
            }

            Section {
                ForEach(Self.appShortcuts, id: \.keys) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.keys)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("In BarShelf")
            } footer: {
                Text("These work in the popup and in this window.")
            }
        }
    }

    private struct AppShortcut {
        let title: String
        let keys: String
    }

    private static let appShortcuts = [
        AppShortcut(title: String(localized: "Search the popup"), keys: "⌘F"),
        AppShortcut(title: String(localized: "Refresh all widgets"), keys: "⌘R"),
        AppShortcut(title: String(localized: "Create a widget"), keys: "⌘N"),
        AppShortcut(title: String(localized: "Open Settings"), keys: "⌘,"),
        AppShortcut(title: String(localized: "Go to page 1–9"), keys: "⌘1 … ⌘9"),
        AppShortcut(title: String(localized: "Previous or next page"), keys: "← →"),
        AppShortcut(title: String(localized: "Quit BarShelf"), keys: "⌘Q"),
    ]
}

// MARK: - Updates

struct UpdatesSettingsPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject private var status = UpdateStatus.shared

    var body: some View {
        SettingsPage {
            Section {
                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.checkForUpdatesAutomatically },
                    set: { value in appPrefs.update { $0.checkForUpdatesAutomatically = value } }
                )) {
                    Text("Check for updates automatically")
                    Text("Look for a new version each time BarShelf starts.")
                }

                LabeledContent {
                    Button("Check Now") { UpdateChecker.check(explicit: true) }
                        .disabled(status.isChecking)
                } label: {
                    Text(statusLine)
                    if let checked = status.lastChecked {
                        Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                    }
                }

                if let skipped = appPrefs.preferences.skippedUpdateVersion {
                    LabeledContent {
                        Button("Stop Skipping") {
                            appPrefs.update { $0.skippedUpdateVersion = nil }
                            // Bring the reminder back now, not at next launch.
                            UpdateChecker.check(explicit: false, prefs: appPrefs)
                        }
                    } label: {
                        Text("Skipping version \(skipped)")
                        Text("You won't be reminded about this version. Newer ones still show up.")
                    }
                }
            }

            Section {
                LabeledContent("Version") {
                    Text(AppVersionInfo.current.versionLabel)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                if let build = AppVersionInfo.current.build {
                    LabeledContent("Build") {
                        Text(build).monospacedDigit().textSelection(.enabled)
                    }
                }
                if let commit = AppVersionInfo.current.sourceCommit {
                    LabeledContent("Source") {
                        HStack(spacing: Spacing.xxs) {
                            if AppVersionInfo.current.isFromDirtyTree {
                                Image(systemName: StatusTone.warning.symbol)
                                    .foregroundStyle(StatusTone.warning.color)
                                    .help("Built from uncommitted changes")
                            }
                            Text(commit).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                if UpdateChecker.isUsingOverriddenFeed {
                    StatusBanner(
                        tone: .warning,
                        message: String(localized: "Updates come from \(UpdateChecker.repository) instead of the official releases.")
                    )
                }
            } header: {
                Text("This Copy")
            }

            PrefsErrorSection(appPrefs: appPrefs)
        }
    }

    private var statusLine: String {
        if status.isChecking { return String(localized: "Checking…") }
        if let available = status.available { return String(localized: "BarShelf \(available) is available") }
        if status.lastChecked != nil { return String(localized: "BarShelf is up to date") }
        return String(localized: "Not checked yet")
    }
}

// MARK: - Privacy

struct PrivacySettingsPage: View {
    @ObservedObject var runtime: WidgetRuntime

    var body: some View {
        SettingsPage {
            let needing = runtime.widgets.filter { runtime.permissionState(for: $0) != .notNeeded }
            Section {
                if needing.isEmpty {
                    Text("No installed widget asks for permissions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(needing) { widget in
                        PermissionRow(runtime: runtime, widget: widget)
                    }
                }
            } header: {
                Text("Widget Permissions")
            } footer: {
                Text("A widget can only run commands, use the network, or read files it declared, and only after you allow it. Revoking stops the widget until you allow it again on its card. Copies of a widget share its permissions.")
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultFileURL()])
                    }
                } label: {
                    Text("Activity log")
                    Text("Every permission decision and every command or request a widget made.")
                }
            }
        }
    }

    private struct PermissionRow: View {
        @ObservedObject var runtime: WidgetRuntime
        let widget: LoadedWidget

        var body: some View {
            let state = runtime.permissionState(for: widget)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text(widget.displayName).font(.headline)
                    Spacer()
                    stateBadge(state)
                    switch state {
                    case .allowed:
                        Button("Revoke") { runtime.revokePermissions(widgetID: widget.id) }
                            .help("Stop this widget until you allow it again")
                    case .denied:
                        Button("Allow") { runtime.approvePermissions(widgetID: widget.id) }
                    case .notAsked:
                        Button("Deny") { runtime.denyPermissions(widgetID: widget.id) }
                        Button("Allow") { runtime.approvePermissions(widgetID: widget.id) }
                    case .notNeeded:
                        EmptyView()
                    }
                }
                ForEach(WidgetPermissionSummary.lines(for: widget.manifest), id: \.self) { line in
                    Label(line.text, systemImage: line.symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.xxs)
            .accessibilityElement(children: .contain)
        }

        @ViewBuilder
        private func stateBadge(_ state: WidgetRuntime.PermissionState) -> some View {
            switch state {
            case .allowed:
                Label("Allowed", systemImage: StatusTone.success.symbol)
                    .foregroundStyle(StatusTone.success.color)
            case .denied:
                Label("Denied", systemImage: StatusTone.critical.symbol)
                    .foregroundStyle(StatusTone.critical.color)
            case .notAsked:
                Label("Waiting for you", systemImage: StatusTone.warning.symbol)
                    .foregroundStyle(StatusTone.warning.color)
            case .notNeeded:
                EmptyView()
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var runtime: WidgetRuntime
    /// Observed separately: refresh stats deliberately do not fire the
    /// runtime's `objectWillChange` (see `RefreshStatsModel`).
    @ObservedObject private var refreshStats: RefreshStatsModel
    @State private var confirmingReset = false
    @Environment(\.undoManager) private var undoManager

    init(appPrefs: AppPrefs, runtime: WidgetRuntime) {
        self.appPrefs = appPrefs
        self.runtime = runtime
        _refreshStats = ObservedObject(wrappedValue: runtime.refreshStats)
    }

    var body: some View {
        SettingsPage {
            Section {
                // The multiplier scales every widget's interval, so a larger
                // number means waiting longer between refreshes.
                Picker(selection: Binding(
                    get: { appPrefs.preferences.refreshMultiplier },
                    set: { value in appPrefs.update { $0.refreshMultiplier = value } }
                )) {
                    Text("Faster").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Slower").tag(2.0)
                    Text("Slowest").tag(4.0)
                } label: {
                    Text("Refresh speed")
                    Text("Faster halves the wait between refreshes; Slower and Slowest double and quadruple it, saving battery and network.")
                }

                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.pauseWhenClosed },
                    set: { value in appPrefs.update { $0.pauseWhenClosed = value } }
                )) {
                    Text("Pause while the popup is closed")
                    Text("Widgets stop refreshing until you open the popup. Menu bar values freeze too, and dim once they're out of date.")
                }
            } header: {
                Text("Battery and Network")
            }

            Section {
                if runtime.widgets.isEmpty {
                    Text("No widgets installed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runtime.widgets) { widget in
                        DiagnosticsRow(widget: widget, stats: refreshStats.stats[widget.id])
                    }
                }
            } header: {
                Text("Refresh History")
            } footer: {
                HStack {
                    Text("How each widget's recent refreshes went.")
                    Spacer()
                    Button("Open Logs", action: Self.openLogsFolder)
                        .buttonStyle(.link)
                }
            }

            Section {
                LabeledContent {
                    Button("Reset Layout…", role: .destructive) { confirmingReset = true }
                        .disabled(!runtime.hasLayoutChanges)
                } label: {
                    Text("Reset layout")
                    Text("Put every widget back on its original page, in its original order and size.")
                }
            }

            PrefsErrorSection(appPrefs: appPrefs)
        }
        .confirmationDialog(
            "Reset the layout of every page?",
            isPresented: $confirmingReset
        ) {
            Button("Reset Layout", role: .destructive) {
                runtime.changeLayout(String(localized: "Reset Layout"), undoManager: undoManager) {
                    runtime.resetLayout()
                }
            }
        } message: {
            Text("Pages, order, and sizes go back to each widget's defaults. Widgets and their settings stay.")
        }
    }

    static func openLogsFolder() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BarShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }
}

/// One widget's refresh record: whether the last one worked, how many have,
/// how long it took, and when.
private struct DiagnosticsRow: View {
    let widget: LoadedWidget
    let stats: WidgetRefreshStats?

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                if hasRun {
                    Label(outcome.text, systemImage: outcome.tone.symbol)
                        .foregroundStyle(outcome.tone.color)
                } else {
                    Text(outcome.text).foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(widget.displayName)
            Text(lastRefresh)
        }
        .accessibilityElement(children: .combine)
    }

    private var outcome: (text: String, tone: StatusTone) {
        switch stats?.lastOutcomeWasSuccess {
        case .some(true): return (String(localized: "Working", comment: "A widget's last refresh succeeded"), .success)
        case .some(false): return (String(localized: "Failing", comment: "A widget's last refresh failed"), .critical)
        case .none: return (String(localized: "Not run yet"), .info)
        }
    }

    private var hasRun: Bool { stats?.lastOutcomeWasSuccess != nil }

    private var detail: String {
        let ok = stats?.successCount ?? 0
        let failed = stats?.failureCount ?? 0
        let duration = stats?.lastDurationMs.map { String(localized: "\(Int($0.rounded())) ms", comment: "A duration in milliseconds") } ?? "–"
        return String(localized: "\(ok) ok · \(failed) failed · \(duration)", comment: "Refresh counts: successful, failed, and how long the last one took")
    }

    private var lastRefresh: String {
        guard let last = stats?.lastRefreshAt else { return String(localized: "Never refreshed") }
        return String(localized: "Refreshed \(last.formatted(.relative(presentation: .named)))")
    }
}
