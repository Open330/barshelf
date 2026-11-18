import AppKit
import ApplicationServices
import Carbon.HIToolbox
import JavaScriptCore

/// Tracks the original physical key until key-up, even if Fn is released first.
/// Only native code runs in the event tap; JavaScript never blocks keyboard input.
package struct AutomationRemapState: Sendable {
    package struct Key: Hashable, Sendable { let code: Int64; let keyboard: Int64 }
    package var held: [Key: Int64] = [:]
    package var fnDown = false

    package mutating func target(code: Int64, keyboard: Int64, down: Bool, fn: Bool,
                         configuration: AutomationScript.Remap) -> Int64? {
        let key = Key(code: code, keyboard: keyboard)
        if !down { return held.removeValue(forKey: key) }
        if let target = held[key] { return target }
        guard (fn || fnDown), configuration.keyboardTypes.contains(keyboard),
              let target = configuration.keys[code] else { return nil }
        held[key] = target
        return target
    }
}

@MainActor
package protocol AutomationRunning: AnyObject {
    var report: ((String) -> Void)? { get set }
    var permissionLost: (() -> Void)? { get set }
    var runtimeFailed: ((String) -> Void)? { get set }
    var inputSourceStatusChanged: ((AutomationInputSource.Status) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Keep held keys on a healthy tap; release them only when events may have
/// been lost. A dead Mach port must be replaced, not merely enabled again.
package enum AutomationTapRecovery {
    package static func recover(valid: Bool, enabled: () -> Bool, releaseKeys: () -> Void,
                        replace: () throws -> Void, enable: () -> Void) throws {
        if !valid {
            releaseKeys()
            try replace()
        } else if !enabled() {
            releaseKeys()
            enable()
        }
        guard enabled() else {
            throw AutomationFailure(String(localized: "Keyboard monitoring could not be restored. Enable the extension again."))
        }
    }
}

@MainActor
package final class AutomationEngine: AutomationRunning {
    package static let signature: OSType = 0x4253_4155 // BSAU; distinct from popup shortcut
    package let script: AutomationScript
    private let windows = AutomationWindows()
    private var hotkeys: [Registration] = []
    private var handler: HandlerInstallation?
    private var keyTap: AutomationKeyTap?
    private var watchdog: Watchdog?
    private var wakeObserver: WakeObservation?
    private var generation = 0
    private var active = false
    package var report: ((String) -> Void)?
    package var permissionLost: (() -> Void)?
    package var runtimeFailed: ((String) -> Void)?
    package var inputSourceStatusChanged: ((AutomationInputSource.Status) -> Void)?
    private var inputSourceMonitorStorage: AutomationInputSourceMonitor?
    private var inputSourceMonitor: AutomationInputSourceMonitor {
        if let monitor = inputSourceMonitorStorage { return monitor }
        let monitor = AutomationInputSourceMonitor { [weak self] status in
            self?.inputSourceStatusChanged?(status)
        }
        inputSourceMonitorStorage = monitor
        return monitor
    }

    package init(script: AutomationScript) {
        self.script = script
        script.report = { [weak self] in self?.report?($0) }
        script.command = { [weak self] name, value in
            guard let self, self.active else { throw AutomationFailure(String(localized: "Extension is disabled.")) }
            switch name {
            case "mouse", "window":
                let number = value.toDouble()
                guard value.isNumber, number.isFinite, number >= 1, number <= 65535, number.rounded() == number else {
                    throw AutomationFailure(String(localized: "Display number must be a positive integer."))
                }
                if name == "mouse" { try self.windows.moveMouse(to: Int(number)) }
                else { try self.windows.moveWindow(to: Int(number)) }
            case "rotate":
                guard let direction = value.toString(), ["forward", "backward"].contains(direction) else {
                    throw AutomationFailure(String(localized: "Rotation direction must be forward or backward."))
                }
                try self.windows.rotate(forward: direction == "forward")
            case "inputSource": try self.inputSourceMonitor.selectNext()
            case "log": self.report?(value.toString() ?? "")
            default: throw AutomationFailure(String(localized: "Unsupported automation action: \(name)."))
            }
        }
    }

    package func start() throws {
        guard !active else { return }
        guard AXIsProcessTrusted() else { throw AutomationFailure(String(localized: "Allow BarShelf in System Settings ▸ Privacy & Security ▸ Accessibility, then enable the extension again.")) }
        do {
            // Take these keys from other BarShelf features (the dock's ⌃⌥
            // profile keys) before registering, rather than failing on them.
            InAppHotkeys.shared.setAutomationKeys(Set(script.bindings.map {
                InAppHotkeys.Key(keyCode: $0.combination.keyCode, modifiers: $0.combination.modifiers)
            }))
            if !script.bindings.isEmpty { try registerHotkeys() }
            if script.remap != nil || !script.keyRemaps.isEmpty { try installTap() }
            active = true
            // A healthy tap must retain held-key state across polling. Reset
            // only after missed events (disabled tap or wake), or on shutdown.
            // Both run on the main thread: a timer on the main run loop, and
            // an observer that asked for the main queue.
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recoverTap() }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = Watchdog(timer)
            wakeObserver = WakeObservation(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.recoverTap(resetKeys: true) } })
        } catch {
            stop()
            throw error
        }
    }

    package func stop() {
        inputSourceMonitorStorage?.stop()
        active = false
        generation += 1
        watchdog = nil
        wakeObserver = nil
        removeTap()
        releaseHeldKeys()
        hotkeys.removeAll()
        InAppHotkeys.shared.setAutomationKeys([])
        handler = nil
    }

    // No deinit: a deinit is not on the main actor, so it cannot call
    // `stop()`. The timer, the wake observer, the registered keys, the event
    // handler and the key tap are each held by an object that undoes it when
    // released, which happens as this goes: an engine dropped without
    // `stop()` leaves nothing registered that points back at it. (The keys
    // it took from other BarShelf features are not handed back then; the
    // controller always stops an engine before letting go of it.)

    /// A registered Carbon hot key, unregistered when released.
    private final class Registration {
        private let ref: EventHotKeyRef
        init(_ ref: EventHotKeyRef) { self.ref = ref }
        deinit { UnregisterEventHotKey(ref) }
    }

    /// The installed Carbon event handler, removed when released.
    private final class HandlerInstallation {
        private let ref: EventHandlerRef
        init(_ ref: EventHandlerRef) { self.ref = ref }
        deinit { RemoveEventHandler(ref) }
    }

    /// The tap watchdog, invalidated when released.
    private final class Watchdog {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        deinit { timer.invalidate() }
    }

    /// The wake observer, removed when released.
    private final class WakeObservation {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private func registerHotkeys() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == AutomationEngine.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id) - 1
            // Carbon delivers the application target's events on the main
            // thread.
            MainActor.assumeIsolated {
                let engine = Unmanaged<AutomationEngine>.fromOpaque(pointer).takeUnretainedValue()
                let generation = engine.generation
                DispatchQueue.main.async { [weak engine] in
                    guard let engine, engine.active, engine.generation == generation else { return }
                    guard AXIsProcessTrusted() else { engine.permissionLost?(); return }
                    engine.script.invoke(index)
                }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &installed)
        if let installed { handler = HandlerInstallation(installed) }
        guard status == noErr else { throw AutomationFailure(String(localized: "Cannot install shortcut event handler (\(status)).")) }
        for (index, binding) in script.bindings.enumerated() {
            var reference: EventHotKeyRef?
            let combo = binding.combination
            let result = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                throw AutomationFailure(String(localized: "Cannot register \(combo.canonicalText). Quit Hammerspoon or change the conflicting shortcut, then try again (\(result))."))
            }
            hotkeys.append(Registration(reference))
        }
    }

    private func installTap() throws {
        let tap = AutomationKeyTap(remap: script.remap, keyRemaps: script.keyRemaps)
        try tap.install()
        keyTap = tap
    }

    private func recoverTap(resetKeys: Bool = false) {
        guard active else { return }
        guard AXIsProcessTrusted() else { permissionLost?(); return }
        if resetKeys { releaseHeldKeys() }
        guard script.remap != nil || !script.keyRemaps.isEmpty else { return }
        let valid = keyTap?.isValid == true
        do {
            try AutomationTapRecovery.recover(valid: valid,
                enabled: { self.keyTap?.isEnabled == true },
                releaseKeys: { self.releaseHeldKeys() },
                replace: { self.removeTap(); try self.installTap() },
                enable: { self.keyTap?.enable() })
        } catch {
            stop()
            runtimeFailed?(error.localizedDescription)
        }
    }

    private func removeTap() {
        // The held-key state lives in the tap: let go of its keys before it
        // is discarded, or a remapped arrow would stay down.
        keyTap?.remove()
        keyTap?.releaseHeldKeys()
        keyTap = nil
    }

    private func releaseHeldKeys() {
        keyTap?.releaseHeldKeys()
    }
}
