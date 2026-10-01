import AppKit
import SwiftUI

/// Reports whether the window hosting this view is actually on screen — not
/// minimized and not completely covered by other windows — so a view can
/// stop background work the user cannot see (issue #1). Zero-size and
/// invisible; place it in a `.background`.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            observers = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
            // A window that is still being ordered in reports its occlusion
            // a moment later; check again once it has settled.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            lastReported = nil
        }

        private func report() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
                && !window.isMiniaturized
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
