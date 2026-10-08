import AppKit
import ApplicationServices
import Carbon.HIToolbox
import JavaScriptCore

/// Tracks the original physical key until key-up, even if Fn is released first.
/// Only native code runs in the event tap; JavaScript never blocks keyboard input.
struct AutomationRemapState {
    struct Key: Hashable { let code: Int64; let keyboard: Int64 }
    var held: [Key: Int64] = [:]
    var fnDown = false

    mutating func target(code: Int64, keyboard: Int64, down: Bool, fn: Bool,
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

protocol AutomationRunning: AnyObject {
    var report: ((String) -> Void)? { get set }
    var permissionLost: (() -> Void)? { get set }
    func start() throws
    func stop()
}

final class AutomationEngine: AutomationRunning {
    static let signature: OSType = 0x4253_4155 // BSAU; distinct from popup shortcut
    let script: AutomationScript
    private let windows = AutomationWindows()
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var remapState = AutomationRemapState()
    private var generation = 0
    private var active = false
    var report: ((String) -> Void)?
    var permissionLost: (() -> Void)?

    init(script: AutomationScript) {
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
            case "log": self.report?(value.toString() ?? "")
            default: throw AutomationFailure(String(localized: "Unsupported automation action: \(name)."))
            }
        }
    }

    func start() throws {
        guard !active else { return }
        guard AXIsProcessTrusted() else { throw AutomationFailure(String(localized: "Allow BarShelf in System Settings → Privacy & Security → Accessibility, then enable the extension again.")) }
        do {
            // Take these keys from other BarShelf features (the dock's ⌃⌥
            // profile keys) before registering, rather than failing on them.
            InAppHotkeys.shared.setAutomationKeys(Set(script.bindings.map {
                InAppHotkeys.Key(keyCode: $0.combination.keyCode, modifiers: $0.combination.modifiers)
            }))
            if !script.bindings.isEmpty { try registerHotkeys() }
            if script.remap != nil { try installTap() }
            active = true
            watchdog = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.recoverTap(resetKeys: true) }
            RunLoop.main.add(watchdog!, forMode: .common)
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.recoverTap(resetKeys: true) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        active = false
        generation += 1
        watchdog?.invalidate()
        watchdog = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        releaseHeldKeys()
        for key in hotkeys { UnregisterEventHotKey(key) }
        hotkeys.removeAll()
        InAppHotkeys.shared.setAutomationKeys([])
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { stop() }

    private func registerHotkeys() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == AutomationEngine.signature else { return OSStatus(eventNotHandledErr) }
            let engine = Unmanaged<AutomationEngine>.fromOpaque(pointer).takeUnretainedValue()
            let generation = engine.generation
            let index = Int(id.id) - 1
            DispatchQueue.main.async { [weak engine] in
                guard let engine, engine.active, engine.generation == generation else { return }
                guard AXIsProcessTrusted() else { engine.permissionLost?(); return }
                engine.script.invoke(index)
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
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
            hotkeys.append(reference)
        }
    }

    private func installTap() throws {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let engine = Unmanaged<AutomationEngine>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Events may have been missed while disabled; release
                    // tracked arrows before accepting new physical key events.
                    engine.releaseHeldKeys()
                    if let tap = engine.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                engine.remap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                throw AutomationFailure(String(localized: "Cannot start Fn-key monitoring. Check Accessibility permission for this BarShelf build; if macOS requests Input Monitoring, allow it and restart BarShelf."))
            }
        tap = newTap
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            throw AutomationFailure(String(localized: "Cannot create keyboard event source."))
        }
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    private func remap(type: CGEventType, event: CGEvent) {
        guard let config = script.remap else { return }
        if type == .flagsChanged {
            remapState.fnDown = event.flags.contains(.maskSecondaryFn)
            return
        }
        guard type == .keyDown || type == .keyUp else { return }
        if let target = remapState.target(code: event.getIntegerValueField(.keyboardEventKeycode),
            keyboard: event.getIntegerValueField(.keyboardEventKeyboardType), down: type == .keyDown,
            fn: event.flags.contains(.maskSecondaryFn), configuration: config) {
            event.setIntegerValueField(.keyboardEventKeycode, value: target)
            event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            event.flags.remove(.maskSecondaryFn)
        }
    }

    private func recoverTap(resetKeys: Bool = false) {
        guard active else { return }
        guard AXIsProcessTrusted() else { permissionLost?(); return }
        if resetKeys { releaseHeldKeys() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            releaseHeldKeys()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func releaseHeldKeys() {
        for code in Set(remapState.held.values) {
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)?.post(tap: .cghidEventTap)
        }
        remapState = AutomationRemapState()
    }
}
