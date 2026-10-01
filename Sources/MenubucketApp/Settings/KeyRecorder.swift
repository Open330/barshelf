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
    @State private var resignObserver: NSObjectProtocol?
    @State private var hint: String?
    /// The window this recorder lives in; keys typed anywhere else are not
    /// its business.
    @State private var hostWindow: NSWindow?

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
        .background(WindowReader { hostWindow = $0 })
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Type Shortcut…" }
        return shortcut.isEmpty ? "Record Shortcut" : HotkeyGrammar.displayText(shortcut)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        hint = String(localized: "Press a key with ⌘, ⌥, ⌃, or ⇧. Esc cancels.")
        let window = hostWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Only this window's keys: typing in the popup or another window
            // while this one waits must reach that window, not become the
            // shortcut.
            guard window == nil || event.window === window else { return event }
            handle(event)
            return nil
        }
        // Clicking away ends recording, as it does in System Settings.
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { stopRecording() }
            }
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
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
            hint = "Add ⌘, ⌥, ⌃, or ⇧ so the shortcut doesn't fire while you type."
            return
        }
        guard let key = HotkeyGrammar.keyName(for: keyCode) else {
            hint = "That key can't be used. Try a letter, a number, Space, Tab, or Return."
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

/// Hands over the NSWindow a SwiftUI view is in, each time it moves into one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }
}
