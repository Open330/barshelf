import AppKit

/// Calls back on the main thread whenever the pointer moves, wherever it is.
///
/// `NSEvent` monitors cannot do this for the menu bar: a global monitor
/// only sees mouse-moved events that some other app's window asked for, and
/// nothing asks for them over the menu bar, so it stays silent exactly where
/// the cluster needs it. A listen-only event tap sees every move before it
/// is delivered. Where the tap cannot be made, a timer reads the pointer
/// instead: slowly while the pointer is somewhere that does not matter, and
/// at `pollInterval` while `isHot` says it does (on or near the menu bar).
/// It used to read it 30 times a second all day.
@MainActor
final class PointerWatcher {
    private let onMove: () -> Void
    private let isHot: (NSPoint) -> Bool
    private var tap: EventTap?
    private var timer: ScopedTimer?
    private var lastPoint: NSPoint?

    /// The event tap and its source on the main run loop, switched off and
    /// taken out when the watcher lets go of it. A main-actor `deinit`
    /// cannot reach these itself; releasing this does the same thing at the
    /// same moment.
    private final class EventTap {
        private let port: CFMachPort
        private let source: CFRunLoopSource

        init(_ port: CFMachPort) {
            self.port = port
            let source: CFRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
        }

        func enable() { CGEvent.tapEnable(tap: port, enable: true) }

        deinit {
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    /// The fallback's rate while hot: smooth enough to follow a pointer
    /// along the chips.
    static let pollInterval: TimeInterval = 1.0 / 30
    /// The fallback's rate elsewhere: quick enough to notice the pointer
    /// arriving at the menu bar.
    static let idlePollInterval: TimeInterval = 0.25

    /// `isHot`: whether the pointer is where it needs following closely.
    init(isHot: @escaping (NSPoint) -> Bool = { _ in true }, onMove: @escaping () -> Void) {
        self.onMove = onMove
        self.isHot = isHot
        if !installTap() { installTimer(interval: Self.idlePollInterval) }
    }

    /// Whether the fallback timer runs, and at which interval (tests).
    var pollingInterval: TimeInterval? { timer?.timer.timeInterval }

    static func interval(hot: Bool) -> TimeInterval { hot ? pollInterval : idlePollInterval }

    // No deinit: the tap and the timer undo themselves when released.

    func stop() {
        tap = nil
        timer = nil
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let watcher = Unmanaged<PointerWatcher>.fromOpaque(refcon).takeUnretainedValue()
                    // `assumeIsolated` holds because the tap's source is on
                    // the main run loop, so this runs on the main thread.
                    MainActor.assumeIsolated { watcher.handle(type) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        tap = EventTap(port)
        return true
    }

    private func handle(_ type: CGEventType) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turns a slow tap off; turn it back on.
            tap?.enable()
        default:
            onMove()
        }
    }

    private func installTimer(interval: TimeInterval) {
        // `assumeIsolated` holds because the timer is added to the main run
        // loop, so it fires on the main thread.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = ScopedTimer(timer)
    }

    private func poll() {
        let point = NSEvent.mouseLocation
        if point != lastPoint {
            lastPoint = point
            onMove()
        }
        // `onMove` may have stopped the watcher.
        guard let timer else { return }
        let wanted = Self.interval(hot: isHot(point))
        if timer.timer.timeInterval != wanted {
            timer.invalidate()
            installTimer(interval: wanted)
        }
    }
}
