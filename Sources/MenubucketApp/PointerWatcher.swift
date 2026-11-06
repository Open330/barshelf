import AppKit

/// Calls back on the main thread whenever the pointer moves, wherever it is.
///
/// `NSEvent` monitors cannot do this for the menu bar: a global monitor
/// only sees mouse-moved events that some other app's window asked for, and
/// nothing asks for them over the menu bar, so it stays silent exactly where
/// the cluster needs it. A listen-only event tap sees every move before it
/// is delivered. Where the tap cannot be made, a timer reads the pointer
/// instead.
final class PointerWatcher {
    private let onMove: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var lastPoint: NSPoint?

    /// The fallback's rate: smooth enough to follow a pointer along the chips.
    static let pollInterval: TimeInterval = 1.0 / 30

    init(onMove: @escaping () -> Void) {
        self.onMove = onMove
        if !installTap() { installTimer() }
    }

    deinit { stop() }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        timer?.invalidate()
        timer = nil
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let watcher = Unmanaged<PointerWatcher>.fromOpaque(refcon).takeUnretainedValue()
                    watcher.handle(type)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func handle(_ type: CGEventType) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turns a slow tap off; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            onMove()
        }
    }

    private func installTimer() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            guard point != self.lastPoint else { return }
            self.lastPoint = point
            self.onMove()
        }
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
