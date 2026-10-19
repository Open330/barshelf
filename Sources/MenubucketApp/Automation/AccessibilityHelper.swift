import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// A small floating panel for allowing BarShelf in System Settings ▸ Privacy &
/// Security ▸ Accessibility: BarShelf's icon to drag into the list, the
/// settings page opened beside it, and the state watched until macOS allows
/// it. Nothing is granted or prompted for automatically; the person does the
/// one thing only they can do, and the panel says when it worked.
///
/// Opened from Automation settings, by `barshelf://accessibility`, or by
/// `barshelf accessibility` — so another Mac can be brought to this point
/// remotely, leaving only the drag.
final class AccessibilityHelper: ObservableObject {
    static let shared = AccessibilityHelper()

    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var panel: NSPanel?
    private var timer: Timer?
    private var onGranted: (() -> Void)?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Shows the panel and opens Accessibility settings next to it.
    /// `onGranted` runs once, when macOS reports BarShelf allowed.
    func show(onGranted: (() -> Void)? = nil) {
        self.onGranted = onGranted
        isTrusted = AXIsProcessTrusted()
        if panel == nil { panel = makePanel() }
        place()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
        if !isTrusted { NSWorkspace.shared.open(Self.settingsURL) }
        startWatching()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func startWatching() {
        timer?.invalidate()
        // macOS sends no notice when the switch flips; a cheap check each
        // second while the panel is up is how anyone finds out.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.check()
        }
        check()
    }

    private func check() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted || (trusted && onGranted != nil) else { return }
        isTrusted = trusted
        if trusted {
            // Allowed stays allowed while the app runs; nothing left to watch.
            timer?.invalidate()
            timer = nil
        }
        if trusted, let granted = onGranted {
            onGranted = nil
            granted()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = String(localized: "Allow BarShelf")
        // Above System Settings, so the icon can be dragged straight into it.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: AccessibilityHelperView(helper: self))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        return panel
    }

    /// Bottom right of the screen, clear of where System Settings opens.
    private func place() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24))
    }
}

struct AccessibilityHelperView: View {
    @ObservedObject var helper: AccessibilityHelper

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if helper.isTrusted {
                Label("BarShelf is allowed in Accessibility.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("Keyboard shortcuts and key remapping can run now.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { helper.close() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Drag BarShelf into the Accessibility list")
                    .font(.headline)
                HStack(alignment: .center, spacing: Spacing.m) {
                    AppDragIcon(url: Bundle.main.bundleURL)
                        .frame(width: 64, height: 64)
                        .help("Drag this into the list in System Settings")
                        .accessibilityLabel(Text("BarShelf app icon, drag into the Accessibility list"))
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("System Settings ▸ Privacy & Security ▸ Accessibility is open. Drag this icon into its list, then turn BarShelf on.")
                        Text("Already listed? Just turn its switch on. Listed and on, but still not allowed? Select it, remove it with −, and drag it in again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS to allow BarShelf…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Accessibility Settings") { helper.openSettings() }
                    Button("Show in Finder") { helper.revealInFinder() }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
        .padding(Spacing.m)
        .frame(width: 400)
    }
}

/// The app's icon as a drag source carrying its file URL — what the
/// Accessibility list accepts when an app is dropped onto it.
private struct AppDragIcon: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DraggableIconView {
        let view = DraggableIconView()
        view.url = url
        view.image = NSWorkspace.shared.icon(forFile: url.path)
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: DraggableIconView, context: Context) {
        view.url = url
    }

    final class DraggableIconView: NSImageView, NSDraggingSource {
        var url: URL?

        override func mouseDown(with event: NSEvent) {
            guard let url else { return }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
