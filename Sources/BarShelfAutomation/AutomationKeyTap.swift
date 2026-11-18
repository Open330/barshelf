import ApplicationServices
// CFMachPort, CFRunLoopSource and CFRunLoop carry no concurrency annotations.
// This file hands them from the thread that installs the tap to the tap's own
// thread and back, which is how they are meant to be used (stopping a run
// loop from another thread is `CFRunLoopStop`'s purpose), so the import says
// the module predates the annotations rather than each use arguing it.
@preconcurrency import CoreFoundation
import CoreGraphics
import Foundation
import os

/// The keyboard event tap, on a thread of its own.
///
/// Every key press on the Mac waits for this callback. It used to run on the
/// app's main run loop, so a busy main thread (a widget refresh, a layout
/// pass) delayed typing, and a long enough stall made macOS switch the tap
/// off. Here nothing but the remap decision shares the thread.
///
/// The remap tables are fixed when the tap is made. Two threads touch the
/// rest (the tap thread, and whoever installs, removes or asks to release
/// keys), so the held keys and the tap's handles each sit behind a lock, and
/// nothing else in the object can change.
package final class AutomationKeyTap: Sendable {
    private struct Held: Sendable {
        var remap = AutomationRemapState()
        var keyRemap = AutomationKeyRemapState()
    }

    private struct Handles: Sendable {
        var port: CFMachPort?
        var source: CFRunLoopSource?
        var runLoop: CFRunLoop?
        var finished: DispatchSemaphore?
    }

    private let remap: AutomationScript.Remap?
    private let keyRemaps: [AutomationKeyRemap]
    private let postKeyUp: @Sendable (Int64) -> Void
    private let held = OSAllocatedUnfairLock(initialState: Held())
    private let handles = OSAllocatedUnfairLock(initialState: Handles())

    /// `postKeyUp` sends a key-up into the session; tests replace it so they
    /// never type into the Mac they run on.
    package init(remap: AutomationScript.Remap?, keyRemaps: [AutomationKeyRemap],
                 postKeyUp: @escaping @Sendable (Int64) -> Void = { code in
                     CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)?
                         .post(tap: .cghidEventTap)
                 }) {
        self.remap = remap
        self.keyRemaps = keyRemaps
        self.postKeyUp = postKeyUp
    }

    // Dropped without `remove()`: close the tap and let go of its keys, or a
    // remapped key would stay down with nothing left to release it.
    deinit {
        remove()
        releaseHeldKeys()
    }

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
            self?.handles.withLock { $0.runLoop = current }
            ready.signal()
            // Runs until `remove()` stops it; the source keeps it alive.
            CFRunLoopRun()
            done.signal()
        }
        thread.name = "dev.barshelf.automation.keytap"
        thread.qualityOfService = .userInteractive
        handles.withLock {
            $0.port = newPort
            $0.source = newSource
            $0.finished = done
        }
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: newPort, enable: true)
    }

    /// Stops the thread and closes the tap. Safe to call twice.
    package func remove() {
        let old = handles.withLock { current -> Handles in
            defer { current = Handles() }
            return current
        }
        let (oldPort, oldSource, oldRunLoop, done) = (old.port, old.source, old.runLoop, old.finished)
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
        handles.withLock {
            $0.port.map { CFMachPortIsValid($0) } == true && $0.source.map { CFRunLoopSourceIsValid($0) } == true
        }
    }

    package var isEnabled: Bool {
        handles.withLock { $0.port }.map { CGEvent.tapIsEnabled(tap: $0) } == true
    }

    package func enable() {
        if let port = handles.withLock({ $0.port }) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Sends key-up for every remapped key still held and forgets them.
    package func releaseHeldKeys() {
        let codes = held.withLock { state -> Set<Int64> in
            defer { state = Held() }
            return Set(Array(state.remap.held.values) + state.keyRemap.held.values.map(\.to))
        }
        codes.forEach(postKeyUp)
    }

    /// Rewrites `event` in place when a rule matches. Native code only; no
    /// JavaScript runs here.
    package func apply(type: CGEventType, to event: CGEvent) {
        if !keyRemaps.isEmpty, type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let keyboard = event.getIntegerValueField(.keyboardEventKeyboardType)
            let flags = event.flags.rawValue
            let rule = held.withLock { [keyRemaps] in
                $0.keyRemap.target(code: code, keyboard: keyboard, down: type == .keyDown,
                    flags: flags, rules: keyRemaps)
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
            held.withLock { $0.remap.fnDown = fnDown }
            return
        }
        guard type == .keyDown || type == .keyUp else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let keyboard = event.getIntegerValueField(.keyboardEventKeyboardType)
        let fn = event.flags.contains(.maskSecondaryFn)
        let target = held.withLock {
            $0.remap.target(code: code, keyboard: keyboard, down: type == .keyDown,
                fn: fn, configuration: remap)
        }
        if let target {
            event.setIntegerValueField(.keyboardEventKeycode, value: target)
            event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            event.flags.remove(.maskSecondaryFn)
        }
    }
}
