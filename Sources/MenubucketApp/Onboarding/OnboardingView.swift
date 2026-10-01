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
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - Steps

    @ViewBuilder
    private var widgetsStep: some View {
        title("Welcome to BarShelf", "One menu bar icon, and a popup of widgets: your usage meters, codes, files, and anything a command line tool can print.")
        Text("We added a few widgets to start with. Keep the ones you want.")
            .foregroundStyle(.secondary)
        VStack(spacing: 0) {
            ForEach(runtime.widgets) { widget in
                switchRow(isOn: Binding(
                    get: { !runtime.prefs.isDisabled(widget.id) },
                    set: { runtime.setWidgetDisabled(widget.id, !$0) }
                )) {
                    Label(widget.displayName, systemImage: widget.manifest.icon ?? "square.dashed")
                }
                if widget.id != runtime.widgets.last?.id { Divider() }
            }
        }
        .padding(.horizontal, Spacing.s)
        .cardSurface()
        Text("You'll find more in the Gallery: usage meters, one-time codes, system sensors, and more.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var accessStep: some View {
        title("Open it from anywhere", "Click the BarShelf icon in the menu bar, or give it a keyboard shortcut.")
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut")
                    Text("For example ⇧⌘B.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                KeyRecorder(
                    shortcut: appPrefs.preferences.popupHotkeyEnabled ? appPrefs.preferences.popupHotkey : "",
                    onRecord: { hotkey.enable(draft: $0, appPrefs: appPrefs) },
                    onClear: { hotkey.disable(appPrefs: appPrefs) }
                )
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
                VStack(alignment: .leading, spacing: 2) {
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
            Text("None of your widgets can do that yet. Widgets like System, Battery, and Weather in the Gallery can; turn it on later in BarShelf ▸ Menu Bar.")
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(candidates) { widget in
                    switchRow(isOn: Binding(
                        get: { runtime.menuBarWidgetIDs.contains(widget.id) },
                        set: { value in runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = value } }
                    )) {
                        Label(widget.displayName, systemImage: widget.manifest.icon ?? "square.dashed")
                    }
                    if widget.id != candidates.last?.id { Divider() }
                }
            }
            .padding(.horizontal, Spacing.s)
            .cardSurface()
            Text("Change this any time in BarShelf ▸ Menu Bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var doneStep: some View {
        title("You're set", "BarShelf lives in the menu bar. A few things to know:")
        VStack(alignment: .leading, spacing: Spacing.s) {
            tip("rectangle.on.rectangle", "Swipe with two fingers, press ← →, or click the page name to switch pages.")
            tip("ellipsis.circle", "The ⋯ menu in the popup edits the shelf, adds widgets, and opens Settings.")
            tip("hand.raised", "A widget that needs to run a command or reach the network asks first, on its card.")
        }
    }

    // MARK: - Pieces

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
        .padding(.vertical, 6)
    }

    private func title(_ heading: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if step == .widgets {
                AccentTile(size: 44) {
                    Image(nsImage: BarShelfStatusIcon.logoImage(size: NSSize(width: 34, height: 26)))
                        .renderingMode(.template)
                }
            }
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
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }

    private var footer: some View {
        HStack {
            // Where the user is, for VoiceOver as well as the eye.
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { dot in
                    Circle()
                        .fill(dot == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            Spacer()
            if step == .done {
                Button("Show BarShelf") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                if step != .widgets {
                    Button("Back") { move(-1) }
                }
                Button("Skip Setup") { finish(false) }
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.m)
    }

    private func move(_ offset: Int) {
        step = Step(rawValue: step.rawValue + offset) ?? step
    }
}
