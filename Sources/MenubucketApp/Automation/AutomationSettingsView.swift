import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    @ObservedObject private var controller: AutomationController
    @State private var draft = ""
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
                        if enabled { controller.apply(source: draft, enabled: true) }
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
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
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
            } header: { Text("Keyboard & Windows") }
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
                                draft = imported
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
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 230)
                    .border(Color.secondary.opacity(0.25))
                    .accessibilityLabel("Automation JavaScript")
                HStack {
                    Button(controller.isRunning ? String(localized: "Save & Reload") : String(localized: "Save Script")) {
                        controller.apply(source: draft, enabled: controller.isRunning)
                    }
                    Button("Revert Draft") { draft = controller.source }
                        .disabled(draft == controller.source)
                    Button("Load Example") { draft = AutomationScript.example }
                    Button("Export…") { export() }
                }
                Text("Edit shortcuts and window actions in JavaScript. Save applies your changes; Revert Draft restores the saved script.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Extension Script") }
            footer: { Text("Saved separately from the original file. Original tool settings are unchanged.") }

            SwiftUI.Section {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    LabeledContent("\(index + 1). \(display.name)", value: String(localized: "Display ID \(display.id)"))
                }
                Text("Screen numbers follow macOS display order, primary first. Check this list after reconnecting monitors.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Displays") }
        }
        .onAppear {
            draft = controller.source
            displays = AutomationWindows.displays
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = AutomationWindows.displays
        }
    }

    /// Active, Inactive, or Active with a warning when the last input source
    /// switch did not take: the extension still runs, so not green.
    private var statusLabel: some View {
        let warning = controller.isRunning && controller.inputSourceStatus.needsAttention
        return Label {
            Text(!controller.isRunning ? String(localized: "Inactive")
                 : warning ? String(localized: "Active — input switching needs attention")
                 : String(localized: "Active"))
        } icon: {
            Image(systemName: !controller.isRunning ? "circle"
                  : warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        }
        .font(.caption)
        .foregroundStyle(!controller.isRunning ? Color.secondary : warning ? Color.orange : Color.green)
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
        if let imported = controller.importFile(url, excludingFunctionKeys: keyMappingsOnly) { draft = imported }
    }

    private func importSettings(path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
        if let imported = controller.importFile(url) { draft = imported }
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
