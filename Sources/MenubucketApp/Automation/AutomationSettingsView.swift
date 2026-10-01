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
                Text("Global shortcuts, Fn arrow keys, and window navigation. Quit Hammerspoon before enabling to avoid duplicate shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Grant Accessibility Access…") { controller.requestAccessibility() }
                if let message = controller.message {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            } header: { Text("Keyboard & Windows") }

            SwiftUI.Section {
                HStack {
                    Button("Import Hammerspoon Settings") {
                        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon/init.lua")
                        if let imported = controller.importFile(url) { draft = imported }
                    }
                    Button("Choose File…") { chooseFile() }
                }
                Text("Imports the supported Fn / monitor / window-cycle Lua profile or a JavaScript extension. Import fills the editor; Save applies it. Unsupported Lua logic is reported instead of discarded.")
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
                    Button(controller.isRunning ? "Save & Reload" : "Save Script") {
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
            footer: { Text("Saved separately from the original file. No Hammerspoon settings are modified.") }

            SwiftUI.Section {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                    LabeledContent("\(index + 1). \(display.name)", value: "Display ID \(display.id)")
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

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lua"), UTType(filenameExtension: "js")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
