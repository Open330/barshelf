import AppKit
import MenubucketCore
import SwiftUI

/// First run (R13 §4.5): a short window that keeps or drops the starter
/// widgets, sets a shortcut and login item, and offers a value for the menu
/// bar — then opens the popup. Shown once, while the starter widgets are new;
/// closing it at any step counts as done.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// Opens the welcome window if this is the first launch that seeded the
    /// starter widgets.
    func showIfNeeded(runtime: WidgetRuntime) {
        guard runtime.prefs.welcomePending, window == nil else { return }
        show(runtime: runtime)
    }

    func show(runtime: WidgetRuntime) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to BarShelf")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(
            runtime: runtime,
            appPrefs: .shared,
            finish: { [weak self] openPopup in self?.finish(runtime: runtime, openPopup: openPopup) }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func finish(runtime: WidgetRuntime, openPopup: Bool) {
        runtime.prefs.dismissWelcome()
        window?.close()
        if openPopup {
            // After the window has gone, so the popup is not dismissed by the
            // focus change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WidgetInstaller.shared.onOpenPopup?()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        HubWindowController.shared.runtime?.prefs.dismissWelcome()
        window = nil
        DispatchQueue.main.async {
            let othersOpen = NSApp.windows.contains { win in
                win !== closing && win.isVisible && win.styleMask.contains(.titled)
            }
            if !othersOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var appPrefs: AppPrefs
    /// `true` opens the popup afterwards.
    let finish: (Bool) -> Void

    @ObservedObject private var hotkey = HotkeyRegistrationCoordinator.shared
    @State private var step: Step
    @State private var loginError: String?
    /// Why adding System for the menu bar step failed, if it did.
    @State private var addError: String?
    /// Bumped on each Allow: the permission store is not observable.
    @State private var approvals = 0
    /// The step's content and the space it has, to fade the bottom edge
    /// only when there is more below.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(runtime: WidgetRuntime, appPrefs: AppPrefs, startAt step: Step = .widgets, finish: @escaping (Bool) -> Void) {
        self.runtime = runtime
        self.appPrefs = appPrefs
        self.finish = finish
        _step = State(initialValue: step)
    }

    enum Step: Int, CaseIterable {
        case widgets, access, menuBar, done
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    switch step {
                    case .widgets: widgetsStep
                    case .access: accessStep
                    case .menuBar: menuBarStep
                    case .done: doneStep
                    }
                }
                .padding(.horizontal, Spacing.l + Spacing.xs)
                .padding(.top, Spacing.l + Spacing.m)
                .padding(.bottom, Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
            .mask { ScrollFadeMask(fades: contentHeight > viewportHeight + 1, height: Spacing.l) }
            Divider()
            footer
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - Steps

    @ViewBuilder
    private var widgetsStep: some View {
        title("Welcome to BarShelf", "One menu bar icon, and a popup of widgets: your usage meters, codes, files, and anything a command line tool can print.")
        Text("We added a few widgets to start with. Turn off the ones you don't need. Ones that ask for permission run after you allow them.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            ForEach(runtime.widgets) { widget in
                let isOn = !runtime.prefs.isDisabled(widget.id)
                switchRow(isOn: Binding(
                    get: { isOn },
                    set: { runtime.setWidgetDisabled(widget.id, !$0) }
                )) {
                    widgetLabel(widget)
                }
                if PermissionStore.requiresApproval(for: widget.manifest) {
                    permissionRow(for: widget, isOn: isOn)
                        .padding(.bottom, Spacing.xs)
                }
                if widget.id != runtime.widgets.last?.id { Divider() }
            }
        }
        .padding(.horizontal, Spacing.s)
        .cardSurface()
        HStack(alignment: .firstTextBaseline) {
            Text("You'll find more in the Gallery, including packs that add a few widgets at once: usage meters, one-time codes, system sensors, and more.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.xs)
            Button("Open Gallery") {
                GalleryWindowController.shared.show()
            }
            .buttonStyle(.glass(.secondary))
            .controlSize(.small)
        }
    }

    /// What a starter asks for, and its own Allow. Keeping the widget on is
    /// not consent: until Allow is pressed — here or on the card — it stays
    /// pending and runs nothing.
    @ViewBuilder
    private func permissionRow(for widget: LoadedWidget, isOn: Bool) -> some View {
        // Depends on `approvals` so the row re-reads the store after Allow.
        let _ = approvals
        let status = runtime.permissionStore.status(for: widget.manifest)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            // What the widget is for, then what it asks for, as on its card.
            if let purpose = WidgetRuntime.permissionPurpose(for: widget) {
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PermissionList(requests: WidgetRuntime.permissionRequests(for: widget))
            if let folder = Self.protectedFolder(in: widget.manifest) {
                Text("macOS will also ask once before BarShelf can open your \(folder) folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.xs) {
                switch status {
                case .approved:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(StatusTone.success.color)
                case .denied:
                    Text("Denied. It runs nothing until you allow it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .pending:
                    // The same words, symbol and tone as the widget's card,
                    // its Shelf chip and its Privacy row.
                    if isOn {
                        Label(PermissionWaiting.title, systemImage: PermissionWaiting.symbol)
                            .font(.caption)
                            .foregroundStyle(PermissionWaiting.tone.color)
                    } else {
                        Label("Turned off", systemImage: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if status != .approved, isOn {
                    // Allow only: turning the widget off above is the way to
                    // say no here. Never the default button.
                    PermissionDecisionButtons(widgetName: widget.displayName) {
                        runtime.approvePermissions(widgetID: widget.id)
                        approvals += 1
                    }
                }
            }
        }
        .padding(.leading, Spacing.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permissions for \(widget.displayName)")
    }

    /// The first folder macOS guards with its own prompt (Downloads,
    /// Documents, Desktop) that the widget reads, as the user sees its name.
    static func protectedFolder(in manifest: Manifest) -> String? {
        for path in manifest.permissions?.readPaths ?? [] {
            let expanded = (path as NSString).expandingTildeInPath
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for (name, label) in [
                ("Downloads", String(localized: "Downloads")),
                ("Documents", String(localized: "Documents")),
                ("Desktop", String(localized: "Desktop")),
            ] {
                let folder = (home as NSString).appendingPathComponent(name)
                if expanded == folder || expanded.hasPrefix(folder + "/") { return label }
            }
        }
        return nil
    }

    @ViewBuilder
    private var accessStep: some View {
        title("Open it from anywhere", "Click the BarShelf icon in the menu bar, or give it a keyboard shortcut.")
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("Shortcut")
                    Text("e.g. ⇧⌘B — click, then press the keys").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                KeyRecorder(
                    shortcut: appPrefs.preferences.popupHotkeyEnabled ? appPrefs.preferences.popupHotkey : "",
                    onRecord: { hotkey.enable(draft: $0, appPrefs: appPrefs) },
                    onClear: { hotkey.disable(appPrefs: appPrefs) }
                )
                // The same capsule as every other button in this window.
                .buttonStyle(.glass(.secondary))
            }
            .padding(.vertical, Spacing.xs)
            if let message = hotkey.message {
                StatusBanner(tone: .warning, message: message)
                    .padding(.bottom, Spacing.xs)
            }
            Divider()
            switchRow(isOn: Binding(
                get: { appPrefs.preferences.launchAtLogin },
                set: { loginError = GeneralSettingsPage.setLaunchAtLogin($0, appPrefs: appPrefs) }
            )) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("Open at login")
                    Text("Start BarShelf when you sign in.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let loginError {
                StatusBanner(tone: .critical, message: loginError)
                    .padding(.bottom, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.s)
        .cardSurface()
    }

    @ViewBuilder
    private var menuBarStep: some View {
        title("Values in the menu bar", "A widget can also show its reading right in the menu bar — a battery level, CPU load, a temperature.")
        let candidates = runtime.menuBarCandidates
        if candidates.isEmpty {
            // The starters show nothing in the menu bar, so offer the one
            // that does and needs no permission: day one should not end on
            // "none of your widgets can".
            HStack(spacing: Spacing.xs) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("System")
                    Text("CPU, memory and disk, with the CPU reading in the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") { addSystemToMenuBar() }
            }
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.s)
            .cardSurface()
            if let addError {
                StatusBanner(tone: .critical, message: addError)
            }
            Text("Battery, Weather and more are in the Gallery. Change this any time in BarShelf ▸ Menu Bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let _ = approvals
            let ordered = Self.menuBarOrder(candidates) { canRun($0) }
            VStack(spacing: 0) {
                ForEach(ordered) { widget in
                    switchRow(isOn: Binding(
                        get: { runtime.menuBarWidgetIDs.contains(widget.id) },
                        set: { value in runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = value } }
                    )) {
                        HStack(spacing: Spacing.xs) {
                            widgetLabel(widget)
                            Spacer(minLength: Spacing.xs)
                            MenuBarRowPreview(
                                widget: widget,
                                model: runtime.cardModel(for: widget.id),
                                canRun: canRun(widget)
                            )
                        }
                    }
                    if widget.id != ordered.last?.id { Divider() }
                }
            }
            .padding(.horizontal, Spacing.s)
            .cardSurface()
            Text("Change this any time in BarShelf ▸ Menu Bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Installs the bundled System widget onto the starters' page and shows
    /// its reading in the menu bar. It ships inside the app, so there is no
    /// download to confirm, and it asks for no permission.
    private func addSystemToMenuBar() {
        addError = nil
        do {
            guard let directory = WidgetInstallFlow.bundledWidgetDirectory(named: "system"),
                  let candidate = try WidgetInstallFlow.discoverBundledWidget(at: directory).candidates.first
            else {
                addError = String(localized: "System isn't in this copy of BarShelf. Add it from the Gallery instead.")
                return
            }
            if !WidgetInstallFlow.isInstalled(id: candidate.manifest.id) {
                try WidgetInstallFlow.install(candidate: candidate)
            }
            runtime.loadWidgets()
            guard let widget = runtime.widgets.first(where: { $0.manifest.id == candidate.manifest.id }) else {
                addError = String(localized: "System was added but hasn't loaded yet. Turn it on later in BarShelf ▸ Menu Bar.")
                return
            }
            if runtime.prefs.override(for: widget.id)?.group == nil {
                runtime.prefs.setOverride(group: WidgetRuntime.starterPage, order: 100, size: nil, for: widget.id)
            }
            runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = true }
        } catch {
            addError = WidgetInstallFlow.userFacingDescription(of: error)
        }
    }

    @ViewBuilder
    private var doneStep: some View {
        title("You're set", "BarShelf lives in the menu bar. A few things to know:")
        VStack(alignment: .leading, spacing: Spacing.s) {
            tip("rectangle.on.rectangle", "Swipe with two fingers, press ← →, or click the page name to switch pages.")
            tip("ellipsis.circle", "Use ⋯ at the top of the popup to add widgets, rearrange them (Edit Shelf, ⌘E), or open Settings.")
            tip("hand.raised", "A widget that needs to run a command or reach the network asks first, on its card.")
        }
    }

    // MARK: - Pieces

    /// Runs now: needs no permission, or has it.
    private func canRun(_ widget: LoadedWidget) -> Bool {
        runtime.permissionStore.status(for: widget.manifest) == .approved
    }

    /// Widgets that can show a reading today first, then those waiting for
    /// permission; each group keeps its own order.
    static func menuBarOrder(_ widgets: [LoadedWidget], canRun: (LoadedWidget) -> Bool) -> [LoadedWidget] {
        widgets.filter(canRun) + widgets.filter { !canRun($0) }
    }

    /// The widget's current menu bar text, e.g. "CPU 23%".
    static func menuBarReading(_ snapshot: WidgetSnapshot) -> String? {
        if let metric = snapshot.statusMetrics?.first(where: { !$0.value.isEmpty }) {
            return [metric.label, metric.value].filter { !$0.isEmpty }.joined(separator: " ")
        }
        guard let label = snapshot.statusLabel, !label.isEmpty else { return nil }
        return [snapshot.statusPrefix ?? "", label].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "CPU —", or "—" alone.
    static func placeholderReading(label: String?) -> String {
        guard let label, !label.isEmpty else { return "—" }
        return "\(label) —"
    }

    /// A widget as every list in the app shows it: its mark, then its name.
    private func widgetLabel(_ widget: LoadedWidget) -> some View {
        HStack(spacing: Spacing.xs) {
            WidgetMark(widget: widget, runtime: runtime)
            Text(widget.displayName)
        }
    }

    /// Label on the leading edge, switch on the trailing one — what a Form
    /// row does, outside a Form.
    private func switchRow<Label: View>(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) -> some View {
        HStack {
            // Shown here, spoken by the switch.
            label().accessibilityHidden(true)
            Spacer()
            Toggle(isOn: isOn) { label() }
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, Spacing.stack)
    }

    private func title(_ heading: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        // The same tile on every step, so the title stays put.
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AccentTile(size: 44) {
                Image(nsImage: BarShelfStatusIcon.logoImage(size: NSSize(width: 34, height: 26)))
                    .renderingMode(.template)
            }
            .accessibilityHidden(true)
            Text(heading)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            // One icon column, whatever each symbol's own width.
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: Self.tipIconWidth)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    static let tipIconWidth: CGFloat = 22

    /// Starters kept on that still wait for Allow.
    private var waitingCount: Int {
        let _ = approvals
        return runtime.widgets.filter { widget in
            !runtime.prefs.isDisabled(widget.id)
                && runtime.permissionStore.status(for: widget.manifest) == .pending
        }.count
    }

    private var footer: some View {
        HStack {
            // Where the user is, for VoiceOver as well as the eye.
            HStack(spacing: Spacing.stack) {
                ForEach(Step.allCases, id: \.self) { dot in
                    Circle()
                        .fill(dot == step ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            // Visible however far the list is scrolled.
            if step == .widgets, waitingCount > 0 {
                Label("\(waitingCount) waiting", systemImage: PermissionWaiting.symbol)
                    .font(.caption)
                    .foregroundStyle(PermissionWaiting.tone.color)
                    .padding(.leading, Spacing.xs)
                    .help(PermissionWaiting.title)
            }

            Spacer()
            if step == .done {
                Button { finish(true) } label: { ShortcutLabel("Show BarShelf", key: "↵") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glass(.primary))
            } else {
                if step != .widgets {
                    Button("Back") { move(-1) }
                        .buttonStyle(.glass(.plain))
                }
                Button("Skip Setup") { finish(false) }
                    .buttonStyle(.glass(.plain))
                Button { move(1) } label: { ShortcutLabel("Continue", key: "↵") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glass(.primary))
            }
        }
        .padding(Spacing.m)
    }

    private func move(_ offset: Int) {
        step = Step(rawValue: step.rawValue + offset) ?? step
    }
}

/// What a row of the onboarding menu bar step would put in the menu bar:
/// its reading when it has one (kept current as it refreshes), else its icon
/// or a dash; for a widget still waiting, that it appears once allowed.
private struct MenuBarRowPreview: View {
    let widget: LoadedWidget
    @ObservedObject var model: WidgetCardModel
    let canRun: Bool

    var body: some View {
        if !canRun {
            Label("Shown after you allow", systemImage: PermissionWaiting.symbol)
                .font(.caption)
                .foregroundStyle(PermissionWaiting.tone.color)
        } else if let reading = OnboardingView.menuBarReading(model.snapshot) {
            Text(verbatim: reading)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if widget.manifest.statusItem?.mode == "icon",
                  let symbol = widget.manifest.statusItem?.icon ?? widget.manifest.icon {
            // An icon-only item: the icon is the preview.
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        } else {
            // No reading yet: its label, if the author gave one, and a dash
            // where the value will be.
            Text(verbatim: OnboardingView.placeholderReading(label: widget.manifest.statusItem?.label.map {
                widget.manifest.localization()?.text($0) ?? $0
            }))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
    }
}
