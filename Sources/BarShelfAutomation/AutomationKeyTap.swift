import ApplicationServices
import CoreGraphics
import Foundation

/// The keyboard event tap, on a thread of its own.
///
/// Every key press on the Mac waits for this callback. It used to run on the
/// app's main run loop, so a busy main thread (a widget refresh, a layout
/// pass) delayed typing, and a long enough stall made macOS switch the tap
/// off. Here nothing but the remap decision shares the thread.
///
/// The remap tables are fixed when the tap is made. The held-key state is the
/// only thing two threads touch (the tap thread, and whoever asks to release
/// keys), so it sits behind a lock.
package final class AutomationKeyTap {
    private let remap: AutomationScript.Remap?
    private let keyRemaps: [AutomationKeyRemap]
    private let postKeyUp: (Int64) -> Void

    private let lock = NSLock()
    private var remapState = AutomationRemapState()
    private var keyRemapState = AutomationKeyRemapState()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var finished: DispatchSemaphore?

    /// `postKeyUp` sends a key-up into the session; tests replace it so they
    /// never type into the Mac they run on.
    package init(remap: AutomationScript.Remap?, keyRemaps: [AutomationKeyRemap],
                 postKeyUp: @escaping (Int64) -> Void = { code in
                     CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)?
                         .post(tap: .cghidEventTap)
                 }) {
        self.remap = remap
        self.keyRemaps = keyRemaps
        self.postKeyUp = postKeyUp
    }

    deinit { remove() }

    /// Creates the tap and starts its thread. Returns once the thread's run
    /// loop is serving it.
    package func install() throws {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<AutomationKeyTap>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Events may have been missed while disabled; release
                    // tracked keys before accepting new physical key events.
                    tap.releaseHeldKeys()
                    tap.enable()
                    return Unmanaged.passUnretained(event)
                }
                tap.apply(type: type, to: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw AutomationFailure(String(localized: "Cannot start keyboard monitoring. Check Accessibility permission for this BarShelf build; if macOS requests Input Monitoring, allow it and restart BarShelf."))
            }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0) else {
            CFMachPortInvalidate(newPort)
            throw AutomationFailure(String(localized: "Cannot create keyboard event source."))
        }
        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let current = CFRunLoopGetCurrent()
            CFRunLoopAddSource(current, newSource, .commonModes)
            self?.lock.withLock { self?.runLoop = current }
            ready.signal()
            // Runs until `remove()` stops it; the source keeps it alive.
            CFRunLoopRun()
            done.signal()
        }
        thread.name = "dev.barshelf.automation.keytap"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            port = newPort
            source = newSource
            finished = done
        }
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: newPort, enable: true)
    }

    /// Stops the thread and closes the tap. Safe to call twice.
    package func remove() {
        let (oldPort, oldSource, oldRunLoop, done) = lock.withLock {
            () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?, DispatchSemaphore?) in
            defer { port = nil; source = nil; runLoop = nil; finished = nil }
            return (port, source, runLoop, finished)
        }
        if let oldPort, CFMachPortIsValid(oldPort) { CGEvent.tapEnable(tap: oldPort, enable: false) }
        if let oldRunLoop {
            if let oldSource { CFRunLoopRemoveSource(oldRunLoop, oldSource, .commonModes) }
            CFRunLoopStop(oldRunLoop)
        }
        if let oldPort { CFMachPortInvalidate(oldPort) }
        // The callback holds this object unretained. Wait for the thread to
        // leave its run loop so no callback is still running when the caller
        // lets go; bounded, so a stuck thread cannot hang shutdown.
        if oldRunLoop != nil { _ = done?.wait(timeout: .now() + 1) }
    }

    package var isValid: Bool {
        lock.withLock {
            port.map { CFMachPortIsValid($0) } == true && source.map { CFRunLoopSourceIsValid($0) } == true
        }
    }

    package var isEnabled: Bool {
        lock.withLock { port }.map { CGEvent.tapIsEnabled(tap: $0) } == true
    }

    package func enable() {
        if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Sends key-up for every remapped key still held and forgets them.
    package func releaseHeldKeys() {
        let codes = lock.withLock { () -> Set<Int64> in
            let held = Set(Array(remapState.held.values) + keyRemapState.held.values.map(\.to))
            remapState = AutomationRemapState()
            keyRemapState = AutomationKeyRemapState()
            return held
        }
        codes.forEach(postKeyUp)
    }

    /// Rewrites `event` in place when a rule matches. Native code only; no
    /// JavaScript runs here.
    package func apply(type: CGEventType, to event: CGEvent) {
        if !keyRemaps.isEmpty, type == .keyDown || type == .keyUp {
            let rule = lock.withLock {
                keyRemapState.target(code: event.getIntegerValueField(.keyboardEventKeycode),
                    keyboard: event.getIntegerValueField(.keyboardEventKeyboardType), down: type == .keyDown,
                    flags: event.flags.rawValue, rules: keyRemaps)
            }
            if let rule {
                event.setIntegerValueField(.keyboardEventKeycode, value: rule.to)
                event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
                event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~rule.mandatory)
            }
            return
        }
        guard let remap else { return }
        if type == .flagsChanged {
            let fnDown = event.flags.contains(.maskSecondaryFn)
            lock.withLock { remapState.fnDown = fnDown }
            return
        }
        guard type == .keyDown || type == .keyUp else { return }
        let target = lock.withLock {
            remapState.target(code: event.getIntegerValueField(.keyboardEventKeycode),
                keyboard: event.getIntegerValueField(.keyboardEventKeyboardType), down: type == .keyDown,
                fn: event.flags.contains(.maskSecondaryFn), configuration: remap)
        }
        if let target {
            event.setIntegerValueField(.keyboardEventKeycode, value: target)
            event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            event.flags.remove(.maskSecondaryFn)
        }
    }
}
