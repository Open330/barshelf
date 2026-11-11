import AppKit
import MenubucketCore
import ServiceManagement
import SwiftUI

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
        SettingsPage(.general) {
            Section {
                MenuBarIconGrid(selection: Binding(
                    get: { appPrefs.preferences.menuBarSymbol },
                    set: { value in appPrefs.update { $0.menuBarSymbol = value } }
                ))
            } header: {
                Text("Menu Bar Icon")
                    .settingsSectionTitle()
            }

            Section {
                // A value of something: segmented (see the rule atop Components).
                Picker(selection: Binding(
                    get: { appPrefs.preferences.popupHeight },
                    set: { value in appPrefs.update { $0.popupHeight = value } }
                )) {
                    Text("Standard").tag(AppPreferences.PopupHeight.standard)
                    Text("Tall").tag(AppPreferences.PopupHeight.tall)
                    Text("Fit to Screen").tag(AppPreferences.PopupHeight.fitScreen)
                } label: {
                    Text("Popup height")
                    Text("How tall the popup grows before its pages scroll. It is shorter when there is less to show.")
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Popup height")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.launchAtLogin },
                    set: setLaunchAtLogin
                )) {
                    Text("Open at login")
                    Text("Start BarShelf when you sign in to your Mac.")
                }
                .accessibilityLabel("Open at login")
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
                .accessibilityLabel("Play a sound when copying")
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

/// The menu bar icon choices as they look in the bar: each one on a strip
/// of menu bar, the chosen one ringed in the accent colour.
private struct MenuBarIconGrid: View {
    @Binding var selection: String

    /// As many columns as fit: six in a wide window, fewer when narrow.
    private let columns = [GridItem(.adaptive(minimum: ControlMetrics.height * 3), spacing: Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.xs) {
            ForEach(choices, id: \.self) { symbol in
                Button { selection = symbol } label: {
                    VStack(spacing: Spacing.xxs) {
                        GeneralSettingsPage.icon(for: symbol)
                            .font(.title3.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: ControlMetrics.height)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .fill(Fill.hover)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: symbol == selection ? ControlMetrics.selectionRing : 0)
                            )
                        Text(GeneralSettingsPage.name(for: symbol))
                            .font(.caption)
                            .foregroundStyle(symbol == selection ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(GeneralSettingsPage.name(for: symbol))
                .accessibilityAddTraits(symbol == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar icon")
    }

    /// The presets, plus a custom symbol set elsewhere so it stays visible.
    private var choices: [String] {
        GeneralSettingsPage.symbolPresets.contains(selection)
            ? GeneralSettingsPage.symbolPresets
            : GeneralSettingsPage.symbolPresets + [selection]
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject private var registration = HotkeyRegistrationCoordinator.shared

    var body: some View {
        SettingsPage(.shortcuts, stats: stats) {
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
                    .settingsSectionTitle()
            }

            Section {
                ForEach(Self.appShortcuts, id: \.keys) { shortcut in
                    LabeledContent(shortcut.title) {
                        KeyCombo(keys: shortcut.keys)
                    }
                }
            } header: {
                Text("In BarShelf")
                    .settingsSectionTitle()
            } footer: {
                Text("These work in the popup and in this window.")
                    .formFooter()
            }
        }
    }

    private var stats: [SettingsStat] {
        let enabled = appPrefs.preferences.popupHotkeyEnabled && !appPrefs.preferences.popupHotkey.isEmpty
        return [
            SettingsStat(value: enabled ? HotkeyGrammar.displayText(appPrefs.preferences.popupHotkey)
                                       : String(localized: "Off", comment: "Shortcuts summary: no global shortcut set"),
                         label: String(localized: "Opens BarShelf")),
            SettingsStat(value: "\(Self.appShortcuts.count)", label: String(localized: "Shortcuts in BarShelf")),
        ]
    }

    private struct AppShortcut {
        let title: String
        let keys: String
    }

    /// Keys as keycaps: "⌘F" one cap, "← →" two, "…" between caps plain.
    private struct KeyCombo: View {
        let keys: String

        var body: some View {
            HStack(spacing: Spacing.xxs) {
                ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, part in
                    if part == "…" {
                        Text(part).foregroundStyle(.secondary)
                    } else {
                        KeyCap(String(part))
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys)
        }
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
        SettingsPage(.updates) {
            Section {
                // The version is the page's figure: big, with what the last
                // check found beside it.
                HStack(spacing: Spacing.s) {
                    Image(systemName: statusTone.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(statusTone.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        MetricText(value: AppVersionInfo.current.versionLabel, size: .compact)
                            .textSelection(.enabled)
                        Text(statusLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let checked = status.lastChecked {
                            Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") { UpdateChecker.check(explicit: true) }
                        .buttonStyle(.glass(status.available == nil ? .secondary : .primary))
                        .disabled(status.isChecking)
                }
                .padding(.vertical, Spacing.xxs)
                .accessibilityElement(children: .contain)

                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.checkForUpdatesAutomatically },
                    set: { value in appPrefs.update { $0.checkForUpdatesAutomatically = value } }
                )) {
                    Text("Check for updates automatically")
                    Text("Look for a new version each time BarShelf starts.")
                }
                .toggleStyle(.switch)
                .accessibilityLabel("Check for updates automatically")

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

            if AppVersionInfo.current.build != nil || AppVersionInfo.current.sourceCommit != nil
                || UpdateChecker.isUsingOverriddenFeed {
            Section {
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
                    .settingsSectionTitle()
            }
            }

            PrefsErrorSection(appPrefs: appPrefs)
        }
    }

    private var statusTone: StatusTone {
        if status.available != nil { return .info }
        if status.lastChecked != nil, !status.isChecking { return .success }
        return .info
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
    @State private var grouping: Grouping = .byWidget

    enum Grouping: Hashable { case byWidget, byCapability }

    var body: some View {
        let needing = runtime.widgets.filter { runtime.permissionState(for: $0) != .notNeeded }
        let waiting = needing.filter { runtime.permissionState(for: $0) == .notAsked }
        let denied = needing.filter { runtime.permissionState(for: $0) == .denied }
        let allowed = needing.filter { runtime.permissionState(for: $0) == .allowed }
        SettingsPage(.privacy, stats: Self.stats(allowed: allowed, waiting: waiting, denied: denied)) {
            if needing.isEmpty {
                Section {
                    Text("No installed widget asks for permissions.")
                        .foregroundStyle(.secondary)
                }
            }

            // What needs a decision comes first.
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { PermissionRow(runtime: runtime, widget: $0) }
                } header: {
                    // The inner style wins: the tone colour over the title's.
                    Label("Waiting for You", systemImage: PermissionWaiting.symbol)
                        .foregroundStyle(PermissionWaiting.tone.color)
                        .settingsSectionTitle()
                }
            }
            if !denied.isEmpty {
                Section {
                    ForEach(denied) { PermissionRow(runtime: runtime, widget: $0) }
                } header: {
                    Text("Denied")
                        .settingsSectionTitle()
                }
            }

            if !allowed.isEmpty || !inEffectGroups.isEmpty {
                Section {
                    switch grouping {
                    case .byWidget:
                        if allowed.isEmpty {
                            Text("No widget is allowed yet.").foregroundStyle(.secondary)
                        }
                        ForEach(allowed) { PermissionRow(runtime: runtime, widget: $0) }
                    case .byCapability:
                        capabilityRows
                    }
                } header: {
                    HStack {
                        Text("Allowed")
                            .settingsSectionTitle()
                        Spacer()
                        Picker("Group", selection: $grouping) {
                            Text("By Widget").tag(Grouping.byWidget)
                            Text("By Capability").tag(Grouping.byCapability)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                } footer: {
                    Text("BarShelf runs only the commands a widget declared, reaches only the hosts it declared, and reads only the paths it declared, after you allow it. A command you allow runs with your access, network included, so allow only widgets you trust. Revoking stops the widget until you allow it again on its card. Copies of a widget share its permissions.")
                        .formFooter()
                }
            }

            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AuditLog.defaultFileURL()])
                    }
                    .buttonStyle(.glass(.secondary))
                } label: {
                    Text("Activity log")
                    Text("Every permission decision and every command or request a widget made.")
                }
            }
        }
    }

    /// Allowed, waiting and (when any) denied widgets, and how many of the
    /// allowed hold sensitive access: secrets, the vault, environment variables.
    static func stats(allowed: [LoadedWidget], waiting: [LoadedWidget], denied: [LoadedWidget]) -> [SettingsStat] {
        // Access, not requests: a widget waiting for you holds nothing yet.
        let sensitive = allowed.filter { widget in
            WidgetPermissionSummary.lines(for: widget.manifest).contains { $0.tone == .sensitive }
        }
        var stats = [
            SettingsStat(value: "\(allowed.count)", label: String(localized: "Allowed", comment: "Privacy summary: widgets allowed")),
            SettingsStat(value: "\(waiting.count)", label: String(localized: "Waiting for you", comment: "Privacy summary: widgets waiting for a decision"),
                         tone: waiting.isEmpty ? nil : PermissionWaiting.tone),
            SettingsStat(value: "\(sensitive.count)", label: String(localized: "Sensitive access", comment: "Privacy summary: widgets with access to secrets, the vault or environment variables")),
        ]
        if !denied.isEmpty {
            stats.append(SettingsStat(value: "\(denied.count)", label: String(localized: "Denied", comment: "Privacy summary: widgets denied")))
        }
        return stats
    }

    /// Access in effect, grouped by kind: allowed widgets and those that
    /// need no approval. Waiting and denied requests are not in effect.
    private var inEffectGroups: [PermissionInventory.Group] {
        PermissionInventory.inEffect(runtime.widgets.map {
            PermissionInventory.Input(id: $0.id, name: $0.displayName, manifest: $0.manifest,
                                      state: runtime.permissionState(for: $0))
        })
    }

    /// The access in effect grouped by kind, each kind expandable.
    @ViewBuilder private var capabilityRows: some View {
        ForEach(inEffectGroups, id: \.kind) { group in
            DisclosureGroup {
                ForEach(group.entries, id: \.self) { entry in
                    CapabilityEntryRow(entry: entry)
                }
            } label: {
                Label {
                    Text(group.kind.title)
                    Text(group.widgetCount == 1
                         ? String(localized: "1 widget")
                         : String(localized: "\(group.widgetCount) widgets"))
                } icon: {
                    Image(systemName: group.kind.symbol)
                }
            }
        }
    }

    /// One command, host or path, and the widgets that may use it.
    private struct CapabilityEntryRow: View {
        let entry: PermissionInventory.Entry

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Text(entry.widgets.map { "\($0.name) (\(Self.stateText($0.state)))" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        static func stateText(_ state: WidgetRuntime.PermissionState) -> String {
            switch state {
            case .allowed: return String(localized: "allowed", comment: "Privacy by capability: a widget's permission state")
            case .denied: return String(localized: "denied", comment: "Privacy by capability: a widget's permission state")
            case .notAsked: return String(localized: "waiting", comment: "Privacy by capability: a widget's permission state")
            case .notNeeded: return String(localized: "no approval needed", comment: "Privacy by capability: a widget's permission state")
            }
        }
    }

    private struct PermissionRow: View {
        @ObservedObject var runtime: WidgetRuntime
        let widget: LoadedWidget

        var body: some View {
            let state = runtime.permissionState(for: widget)
            HStack(alignment: .top, spacing: Spacing.s) {
                WidgetMark(widget: widget, runtime: runtime)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(widget.displayName).font(.headline)
                    FlowLayout {
                        ForEach(WidgetPermissionSummary.lines(for: widget.manifest), id: \.self) { line in
                            PermissionChip(line: line)
                        }
                    }
                }
                Spacer(minLength: Spacing.xs)
                switch state {
                case .allowed:
                    // Always there for keyboard, VoiceOver and automation;
                    // quiet (text until hovered) because the decision is made.
                    Button("Revoke") { runtime.revokePermissions(widgetID: widget.id) }
                        .buttonStyle(.glass(.plain))
                        .controlSize(.small)
                        .help("Stop this widget until you allow it again")
                    Label("Allowed", systemImage: StatusTone.success.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .symbolRenderingMode(.multicolor)
                case .denied:
                    PermissionDecisionButtons(widgetName: widget.displayName) {
                        runtime.approvePermissions(widgetID: widget.id)
                    }
                case .notAsked:
                    PermissionDecisionButtons(
                        widgetName: widget.displayName,
                        onDeny: { runtime.denyPermissions(widgetID: widget.id) },
                        onAllow: { runtime.approvePermissions(widgetID: widget.id) }
                    )
                case .notNeeded:
                    EmptyView()
                }
            }
            .padding(.vertical, Spacing.xxs)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel(widget.displayName)
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
        SettingsPage(.advanced, stats: stats) {
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
                .accessibilityLabel("Refresh speed")

                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.pauseWhenClosed },
                    set: { value in appPrefs.update { $0.pauseWhenClosed = value } }
                )) {
                    Text("Pause while the popup is closed")
                    Text("Hidden widgets stop refreshing until you open the popup. Menu bar and Dock widgets keep updating; remove them from those surfaces to stop their background updates.")
                }
                .accessibilityLabel("Pause while the popup is closed")
                Text("Script timers can keep running in the background when this option is off. Turning it on also pauses hidden script timers; overdue callbacks resume once when the widget becomes visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Battery and Network")
                    .settingsSectionTitle()
            }

            Section {
                if runtime.widgets.isEmpty {
                    Text("No widgets installed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(runtime.widgets) { widget in
                        DiagnosticsRow(widget: widget, runtime: runtime, stats: refreshStats.stats[widget.id])
                    }
                }
            } header: {
                Text("Refresh History")
                    .settingsSectionTitle()
            } footer: {
                HStack {
                    Text("How each widget's recent refreshes went.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    /// How the widgets' last refreshes went, as the page's figures.
    private var stats: [SettingsStat] {
        let outcomes = runtime.widgets.map { refreshStats.stats[$0.id]?.lastOutcomeWasSuccess }
        let failing = outcomes.filter { $0 == false }.count
        return [
            SettingsStat(value: "\(outcomes.filter { $0 == true }.count)",
                         label: String(localized: "Working", comment: "Advanced summary: widgets whose last refresh worked")),
            SettingsStat(value: "\(failing)",
                         label: String(localized: "Failing", comment: "Advanced summary: widgets whose last refresh failed"),
                         tone: failing > 0 ? .critical : nil),
            SettingsStat(value: "\(outcomes.filter { $0 == nil }.count)",
                         label: String(localized: "Not run yet")),
        ]
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
    let runtime: WidgetRuntime
    let stats: WidgetRefreshStats?

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: Spacing.hair) {
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
            HStack(spacing: Spacing.xs) {
                WidgetMark(widget: widget, runtime: runtime)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(widget.displayName)
                    Text(lastRefresh)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
