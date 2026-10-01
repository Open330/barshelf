import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Records a keyboard shortcut by pressing it, the way System Settings does,
/// instead of typing "cmd+shift+b". Click it, press the keys; Esc cancels and
/// Delete clears.
struct KeyRecorder: View {
    /// The shortcut in `HotkeyGrammar` text, or "" for none.
    let shortcut: String
    let onRecord: (String) -> Void
    var onClear: (() -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                Button(action: toggleRecording) {
                    Text(label)
                        .frame(minWidth: 110)
                }
                .accessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut \(label)")
                .accessibilityHint("Press to record a new shortcut")
                if !shortcut.isEmpty, let onClear, !isRecording {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear Shortcut")
                    .accessibilityLabel("Clear Shortcut")
                }
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return String(localized: "Type Shortcut…") }
        return shortcut.isEmpty ? String(localized: "Record Shortcut") : HotkeyGrammar.displayText(shortcut)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        hint = String(localized: "Press a key with ⌘, ⌥, ⌃, or ⇧. Esc cancels.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        hint = nil
    }

    private func handle(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(keyCode) == kVK_Escape, flags.isEmpty {
            stopRecording()
            return
        }
        if Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete, flags.isEmpty {
            stopRecording()
            onClear?()
            return
        }
        guard !flags.isEmpty else {
            hint = String(localized: "Add ⌘, ⌥, ⌃, or ⇧ so the shortcut doesn't fire while you type.")
            return
        }
        guard let key = HotkeyGrammar.keyName(for: keyCode) else {
            hint = String(localized: "That key can't be used. Try a letter, a number, Space, Tab, or Return.")
            return
        }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.control) { parts.append("ctrl") }
        parts.append(key)
        stopRecording()
        onRecord(parts.joined(separator: "+"))
    }
}
