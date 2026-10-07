import AppKit
import Combine
import MenubucketCore
import SwiftUI

/// A borderless panel at the Dock's window level. Never activates BarShelf,
/// so clicking an icon leaves the frontmost app frontmost until the click
/// itself switches apps.
final class DockPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // Every Space, never in Mission Control's window list or ⌘` cycling;
        // full-screen apps hide it, as they hide the Apple Dock.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// First clicks act right away (the panel is never key when they arrive), and
/// a two-finger swipe or ⌘-scroll over the dock switches profiles.
final class DockHostingView<Content: View>: NSHostingView<Content> {
    var onSwipe: ((Int) -> Void)?
    /// The content's ideal size changed (items, sizes, running apps).
    var onIdealSizeChange: (() -> Void)?
    private var accumulated: CGFloat = 0
    private var firedThisGesture = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIdealSizeChange?()
    }

    override func scrollWheel(with event: NSEvent) {
        // Momentum after the fingers lift would switch a second time.
        guard event.momentumPhase.isEmpty else { return }
        if event.modifierFlags.contains(.command) {
            // A mouse wheel notch, or a decent trackpad flick: one profile.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
            if abs(delta) >= 1 { onSwipe?(delta > 0 ? -1 : 1) }
            return
        }
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began {
            accumulated = 0
            firedThisGesture = false
        }
        accumulated += event.scrollingDeltaX
        if !firedThisGesture, abs(accumulated) > 60 {
            firedThisGesture = true
            // Content follows the fingers: swiping left brings the next one.
            onSwipe?(accumulated < 0 ? 1 : -1)
        }
        if event.phase == .ended || event.phase == .cancelled {
            accumulated = 0
            firedThisGesture = false
        }
    }
}

/// Shows the BarShelf Dock on its screen edge, hides it when auto-hide says
/// so, and tells the runtime which dock widgets are on screen (R15).
final class DockPanelController {
    private let store: DockStore
    private let runtime: WidgetRuntime
    private let running = RunningApps()
    private let panel = DockPanel()
    private var hostingView: DockHostingView<DockView>!
    private var cancellables: Set<AnyCancellable> = []
    private var mouseMonitors: [Any] = []
    private var restingSize: CGSize = .zero
    private var isHovering = false
    private var measurePending = false
    /// Whether the dock is out (not slid away by auto-hide).
    private var isRevealed = true
    private var hideWorkItem: DispatchWorkItem?

    /// The edge band, in points, that brings an auto-hidden dock back.
    static let revealBand: CGFloat = 2
    /// Gap between the dock and the screen edge.
    static let edgeGap: CGFloat = 4

    var onOpenSettings: (() -> Void)?

    /// The dock panel's frame while it is on screen, for menus opened by an
    /// accessibility action rather than a click. One dock per app.
    private(set) static var currentFrame: NSRect?

    init(store: DockStore, runtime: WidgetRuntime) {
        self.store = store
        self.runtime = runtime
        let view = DockView(
            store: store, runtime: runtime, running: running,
            onHoverChange: { [weak self] hovering in self?.hoverChanged(hovering) },
            onOpenSettings: { [weak self] in self?.onOpenSettings?() }
        )
        hostingView = DockHostingView(rootView: view)
        // The ideal size is read, not obeyed: the hosting view sits in a
        // plain container that the panel's frame drives, so the bar's size
        // can be measured without the window snapping to it.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.onSwipe = { [weak store] offset in store?.activate(offset: offset) }
        hostingView.onIdealSizeChange = { [weak self] in self?.setNeedsMeasure() }
        let container = NSView(frame: panel.contentLayoutRect)
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
        panel.contentView = container

        store.$configuration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.configurationChanged() }
            .store(in: &cancellables)
        runtime.$widgets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reportVisibleWidgets()
                self?.setNeedsMeasure()
            }
            .store(in: &cancellables)
        running.$apps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setNeedsMeasure() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.placePanel(animated: false) }
            .store(in: &cancellables)
        configurationChanged()
    }

    deinit {
        removeMouseMonitors()
    }

    private var config: DockConfiguration { store.configuration }

    // MARK: Showing

    private func configurationChanged() {
        guard config.mode.showsDock else {
            panel.orderOut(nil)
            removeMouseMonitors()
            runtime.setDockWidgetIDs([])
            return
        }
        installMouseMonitorsIfNeeded()
        if !config.autoHide { isRevealed = true }
        setNeedsMeasure()
        placePanel(animated: false)
        if isRevealed { panel.orderFrontRegardless() }
        reportVisibleWidgets()
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if !hovering { setNeedsMeasure() }
    }

    /// Measures the bar once SwiftUI has caught up with the change that asked
    /// for it (`@Published` fires before the new value is stored).
    private func setNeedsMeasure() {
        guard !measurePending else { return }
        measurePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurePending = false
            self.measure()
        }
    }

    private func measure() {
        guard config.mode.showsDock, !isHovering else { return }
        let fitting = hostingView.intrinsicContentSize
        // The edge gap is part of the SwiftUI padding; the bar is the rest.
        let size = config.edge.isVertical
            ? CGSize(width: fitting.width - Self.edgeGap, height: fitting.height)
            : CGSize(width: fitting.width, height: fitting.height - Self.edgeGap)
        guard size.width > 0, size.height > 0, size != restingSize else { return }
        restingSize = size
        placePanel(animated: false)
    }

    /// The headroom around the bar that magnified icons and their labels
    /// draw into. Transparent, so clicks there reach the windows below.
    private var headroom: (along: CGFloat, across: CGFloat) {
        let tile = CGFloat(config.tileSize)
        let magnifies = config.style == .classic && config.magnification
        let grow = magnifies ? tile * DockView.maxMagnification : 0
        // Labels sit past the grown icon; the profile banner past the bar.
        return (along: magnifies ? tile * 2.5 : tile, across: grow + 48)
    }

    private var screen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// The panel frame for the current size and edge, out on screen or slid
    /// past the edge (the current state unless `revealed` says otherwise).
    private func targetFrame(revealed: Bool? = nil) -> NSRect? {
        let isRevealed = revealed ?? self.isRevealed
        guard let screen, restingSize != .zero else { return nil }
        let visible = screen.visibleFrame
        let full = screen.frame
        let room = headroom
        switch config.edge {
        case .bottom:
            let width = min(restingSize.width + room.along, full.width)
            let height = restingSize.height + room.across + Self.edgeGap
            // Above the Apple Dock when it shares the edge and stays up.
            var y = visible.minY
            if !isRevealed { y = full.minY - height }
            return NSRect(x: visible.midX - width / 2, y: y, width: width, height: height)
        case .left, .right:
            let width = restingSize.width + room.across + Self.edgeGap
            let height = min(restingSize.height + room.along, visible.height)
            let y = visible.midY - height / 2
            if config.edge == .left {
                let x = isRevealed ? visible.minX : full.minX - width
                return NSRect(x: x, y: y, width: width, height: height)
            }
            let x = isRevealed ? visible.maxX - width : full.maxX
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }

    private func placePanel(animated: Bool, completion: (() -> Void)? = nil) {
        guard let frame = targetFrame() else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                completion?()
            }
        } else {
            panel.setFrame(frame, display: true)
            completion?()
        }
        Self.currentFrame = isRevealed ? frame : nil
    }

    // MARK: Auto-hide

    private func installMouseMonitorsIfNeeded() {
        guard mouseMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
    }

    private func mouseMoved() {
        guard config.mode.showsDock, config.autoHide, let screen else { return }
        let point = NSEvent.mouseLocation
        let full = screen.frame
        let atEdge: Bool = switch config.edge {
        case .bottom: point.y <= full.minY + Self.revealBand && point.x >= full.minX && point.x <= full.maxX
        case .left: point.x <= full.minX + Self.revealBand && point.y >= full.minY && point.y <= full.maxY
        case .right: point.x >= full.maxX - Self.revealBand - 1 && point.y >= full.minY && point.y <= full.maxY
        }
        if !isRevealed {
            if atEdge { setRevealed(true) }
            return
        }
        let inside = barFrame().insetBy(dx: -12, dy: -12).contains(point) || atEdge
        if inside {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else if hideWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.hideWorkItem = nil
                self?.setRevealed(false)
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    /// The bar's own frame on screen, without the headroom.
    private func barFrame() -> NSRect {
        let frame = panel.frame
        switch config.edge {
        case .bottom:
            return NSRect(
                x: frame.midX - restingSize.width / 2, y: frame.minY,
                width: restingSize.width, height: restingSize.height + Self.edgeGap
            )
        case .left:
            return NSRect(
                x: frame.minX, y: frame.midY - restingSize.height / 2,
                width: restingSize.width + Self.edgeGap, height: restingSize.height
            )
        case .right:
            return NSRect(
                x: frame.maxX - restingSize.width - Self.edgeGap, y: frame.midY - restingSize.height / 2,
                width: restingSize.width + Self.edgeGap, height: restingSize.height
            )
        }
    }

    private func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        // A menu or a drag in flight keeps the dock out.
        if !revealed, NSEvent.pressedMouseButtons != 0 { return }
        isRevealed = revealed
        if revealed {
            // Start just past the edge, then slide in.
            if let hidden = targetFrame(revealed: false) { panel.setFrame(hidden, display: false) }
            panel.orderFrontRegardless()
            placePanel(animated: true)
        } else {
            // Slide out, then leave the screen for real: past the edge could
            // be another display.
            placePanel(animated: true) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        reportVisibleWidgets()
    }

    // MARK: Widgets on screen

    private func reportVisibleWidgets() {
        guard config.mode.showsDock, isRevealed else {
            runtime.setDockWidgetIDs([])
            return
        }
        runtime.setDockWidgetIDs(Set(config.activeWidgetIDs))
    }
}
