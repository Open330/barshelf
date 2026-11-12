import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    @ObservedObject private var controller: AutomationController
    /// The editor's text: unsaved edits if there are any, else the saved script.
    private var draft: String { controller.draft ?? controller.source }
    private var hasUnsavedChanges: Bool { controller.draft != nil }
    @State private var displays: [AutomationWindows.Display] = []

    init(controller: AutomationController = .shared) {
        self.controller = controller
    }

    var body: some View {
        Group {
            SwiftUI.Section {
                Toggle("Enable Keyboard & Window Extension", isOn: Binding(
                    get: { controller.isRunning },
                    set: { enabled in
                        // Enabling runs the saved script. Unsaved edits are
                        // applied only by Save, as the editor says.
                        if enabled { controller.apply(source: controller.source, enabled: true) }
                        else { controller.disable() }
                    }
                ))
                .accessibilityLabel("Enable Keyboard & Window Extension")
                statusLabel
                Text("Global shortcuts, key remapping, and window navigation. Quit Hammerspoon and disable matching Karabiner rules before enabling.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow in Accessibility…") { controller.requestAccessibility() }
                // The input status below says it already; not twice.
                if let message = controller.message, message != controller.inputSourceStatus.message {
                    // A warning carries its symbol as well as its colour.
                    StatusBanner(tone: .warning, message: message)
                }
                if controller.isRunning { inputSourceStatusView }
                ForEach(controller.systemShortcutConflicts) { conflict in
                    StatusBanner(
                        tone: .warning,
                        message: String(localized: "\(conflict.displayBinding) is also the macOS shortcut “\(conflict.systemName)”. Both run on every press — switching input sources this way switches twice and ends where it started. Turn that shortcut off in System Settings.")
                    ) {
                        Button("Keyboard Shortcuts…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: { Text("Keyboard & Windows").settingsSectionTitle() }
            .onAppear { controller.refreshSystemShortcutConflicts() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                controller.refreshSystemShortcutConflicts()
            }

            SwiftUI.Section {
                HStack {
                    Menu("Import Settings") {
                        Button("Hammerspoon") {
                            importSettings(path: ".hammerspoon/init.lua")
                        }
                        Button("Karabiner-Elements") {
                            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map {
                                URL(fileURLWithPath: $0, isDirectory: true)
                            } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
                            if let imported = controller.importFile(base.appendingPathComponent("karabiner/karabiner.json")) {
                                replaceDraft(with: imported)
                            }
                        }
                        Button("Karabiner Key Mappings Only…") {
                            let alert = NSAlert()
                            alert.messageText = String(localized: "Import key mappings without function key settings?")
                            alert.informativeText = String(localized: "Function and media key customizations will not be migrated. After quitting Karabiner, those keys use native macOS behavior, which may differ. Other unsupported behavior still blocks import. This only creates an editor draft.")
                            alert.addButton(withTitle: String(localized: "Review Key Mappings"))
                            alert.addButton(withTitle: String(localized: "Cancel"))
                            if alert.runModal() == .alertFirstButtonReturn { chooseFile(keyMappingsOnly: true) }
                        }
                    }
                    Button("Choose File…") { chooseFile() }
                }
                Text("Import Hammerspoon navigation, Karabiner key mappings, or JavaScript. Import fills the editor; Save applies it. Unsupported behavior is reported before importing. Disable the original tool's matching rules before enabling.")
                    .font(.caption).foregroundStyle(.secondary)
                if let summary = controller.importSummary {
                    Text(summary).font(.caption).textSelection(.enabled)
                }
                // Code: one line per line, scrolled sideways rather than
                // wrapped mid-token, in the size of the notes around it.
                ScriptEditor(text: Binding(get: { draft }, set: { controller.setDraft($0) }))
                    .frame(minHeight: 230)
                    .border(Fill.hairline)
                    .accessibilityLabel("Automation JavaScript")
                HStack {
                    Button(controller.isRunning ? String(localized: "Save & Reload") : String(localized: "Save Script")) {
                        if controller.apply(source: draft, enabled: controller.isRunning) {
                            controller.setDraft(controller.source)
                        }
                    }
                    // Running, it doubles as Reload.
                    .disabled(!hasUnsavedChanges && !controller.isRunning)
                    Button("Revert Draft") { controller.setDraft(controller.source) }
                        .disabled(!hasUnsavedChanges)
                    Button("Load Example") { replaceDraft(with: AutomationScript.example) }
                    Button("Export…") { export() }
                    if hasUnsavedChanges {
                        Label("Unsaved changes", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(StatusTone.warning.color)
                            .imageScale(.small)
                    }
                }
                Text("Edit shortcuts and window actions in JavaScript. Save applies your changes; Revert Draft restores the saved script.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Extension Script").settingsSectionTitle() }
            footer: { Text("Saved separately from the original file. Original tool settings are unchanged.").formFooter() }

            SwiftUI.Section {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    LabeledContent("\(index + 1). \(display.name)", value: String(localized: "Display ID \(display.id)"))
                }
                Text("Screen numbers follow macOS display order, primary first. Check this list after reconnecting monitors.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Displays").settingsSectionTitle() }
        }
        .onAppear {
            displays = AutomationWindows.displays
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = AutomationWindows.displays
        }
    }

    /// Active, Off, or Active with a warning when the last input source
    /// switch did not take: the extension still runs, so not green. A
    /// status dot and a word, as elsewhere: a hollow circle read as an
    /// unchosen radio button.
    private var statusLabel: some View {
        let warning = controller.isRunning && controller.inputSourceStatus.needsAttention
        let tone: Color = !controller.isRunning ? .secondary : warning ? StatusTone.warning.color : StatusTone.success.color
        return HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(tone)
                .frame(width: Spacing.stack, height: Spacing.stack)
                .accessibilityHidden(true)
            Text(!controller.isRunning ? String(localized: "Off", comment: "Automation status: the extension is not running")
                 : warning ? String(localized: "Active — input switching needs attention")
                 : String(localized: "Active"))
                .foregroundStyle(controller.isRunning ? tone : .secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// On or off, and what the saved script holds.
    static func stats(controller: AutomationController) -> [SettingsStat] {
        let summary = controller.savedSummary()
        let warning = controller.isRunning && controller.inputSourceStatus.needsAttention
        return [
            SettingsStat(
                value: controller.isRunning ? String(localized: "On", comment: "Automation summary: extension running")
                                            : String(localized: "Off", comment: "Automation status: the extension is not running"),
                label: String(localized: "Keyboard & Windows"),
                tone: warning ? .warning : nil
            ),
            SettingsStat(value: summary.map { "\($0.shortcuts)" } ?? "–",
                         label: String(localized: "Shortcuts in the script", comment: "Automation summary")),
            SettingsStat(value: summary.map { "\($0.remaps)" } ?? "–",
                         label: String(localized: "Remapped keys", comment: "Automation summary")),
        ]
    }

    /// The last input source switch. "Changed" only means the selected
    /// source changed; BarShelf cannot see whether the focused app's typing
    /// followed, so the copy does not claim it.
    @ViewBuilder
    private var inputSourceStatusView: some View {
        switch controller.inputSourceStatus {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking the last input source switch…")
                .font(.caption).foregroundStyle(.secondary)
        case .changed:
            Text("The input source changed after the last switch. Check that the app you type in follows it.")
                .font(.caption).foregroundStyle(.secondary)
        case .needsAttention(let reason):
            StatusBanner(
                tone: .warning,
                message: reason.isEmpty
                    ? String(localized: "The last input source switch did not change the input source. Other shortcuts keep working. Check “Select next source in Input menu” in Keyboard Shortcuts.")
                    : reason
            ) {
                Button("Keyboard Shortcuts…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func chooseFile(keyMappingsOnly: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = keyMappingsOnly ? [.json]
            : [UTType(filenameExtension: "lua"), UTType(filenameExtension: "js"), .json].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let imported = controller.importFile(url, excludingFunctionKeys: keyMappingsOnly) { replaceDraft(with: imported) }
    }

    /// Fills the editor from an import or the example, asking first when
    /// that would discard changes that were never saved.
    private func replaceDraft(with text: String) {
        if controller.replacingDraftLosesChanges(with: text) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Replace your unsaved changes?")
            alert.informativeText = String(localized: "The editor has changes you haven’t saved. They’ll be replaced and can’t be brought back.")
            alert.addButton(withTitle: String(localized: "Replace"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        controller.setDraft(text)
    }

    private func importSettings(path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
        if let imported = controller.importFile(url) { replaceDraft(with: imported) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "automation.js"
        panel.allowedContentTypes = [UTType(filenameExtension: "js")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.write(to: url, atomically: true, encoding: .utf8) }
        catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

/// A plain-text code editor: monospaced at the size of a caption, no line
/// wrapping (long lines scroll sideways), no smart quotes or dashes.
private struct ScriptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.textContainerInset = NSSize(width: Spacing.xxs, height: Spacing.xxs)
        // No wrapping: the container grows with the longest line.
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
