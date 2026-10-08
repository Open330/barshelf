import Carbon.HIToolbox
import Combine
import Foundation
import MenubucketCore

/// Which ⌃⌥ numbers the dock could not take, for settings to show.
/// Positions are 1-based.
final class DockHotkeyStatus: ObservableObject {
    static let shared = DockHotkeyStatus()
    /// Owned by another app.
    @Published fileprivate(set) var unavailable: Set<Int> = []
    /// Used by the Automation script, which wins.
    @Published fileprivate(set) var heldByAutomation: Set<Int> = []
}

/// ⌃⌥1…9: switch to the first nine dock profiles (R15). Carbon hot keys, like
/// the popup shortcut, so no Accessibility permission is needed. Its own
/// signature keeps its presses apart from the popup shortcut's handler.
final class DockHotkeys {
    static let signature: OSType = 0x4253_444B // 'BSDK'
    static let modifiers = UInt32(controlKey | optionKey)
    static let digitKeyCodes: [UInt32] = [
        UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
        UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
        UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
    ]

    private let store: DockStore
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var desiredCount = 0
    private var unavailable: Set<Int> = [] {
        didSet { DockHotkeyStatus.shared.unavailable = unavailable }
    }
    private var heldByAutomation: Set<Int> = [] {
        didSet { DockHotkeyStatus.shared.heldByAutomation = heldByAutomation }
    }
    private var cancellable: AnyCancellable?
    private var automationObserver: UUID?

    init(store: DockStore) {
        self.store = store
        // Automation claiming or releasing keys: register again around them.
        automationObserver = InAppHotkeys.shared.observe { [weak self] in
            guard let self else { return }
            self.register(count: self.desiredCount)
        }
        cancellable = store.$configuration
            .map { $0.profileHotkeysEnabled ? min($0.profiles.count, DockConfiguration.hotkeyProfileLimit) : 0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.register(count: count) }
    }

    deinit {
        if let automationObserver { InAppHotkeys.shared.removeObserver(automationObserver) }
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Shown in settings beside each profile: "⌃⌥1".
    static func label(forPosition position: Int) -> String? {
        guard (1...DockConfiguration.hotkeyProfileLimit).contains(position) else { return nil }
        return "⌃⌥\(position)"
    }

    /// Registers the first `count` ⌃⌥ numbers, leaving out the ones the
    /// Automation script uses. Called again whenever either side changes; a
    /// key another app held is retried each time.
    private func register(count: Int) {
        desiredCount = count
        unregisterAll()
        guard count > 0 else { return }
        installHandlerIfNeeded()
        let automation = InAppHotkeys.shared.automation
        var failed: Set<Int> = []
        var held: Set<Int> = []
        for (index, keyCode) in Self.digitKeyCodes.prefix(count).enumerated() {
            let position = index + 1
            if automation.contains(InAppHotkeys.Key(keyCode: keyCode, modifiers: Self.modifiers)) {
                held.insert(position)
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(position))
            if RegisterEventHotKey(keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            } else {
                failed.insert(position)
            }
        }
        unavailable = failed
        heldByAutomation = held
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        unavailable = []
        heldByAutomation = []
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                ) == noErr, id.signature == DockHotkeys.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkeys = Unmanaged<DockHotkeys>.fromOpaque(userData).takeUnretainedValue()
                let position = Int(id.id)
                DispatchQueue.main.async { hotkeys.pressed(position: position) }
                return noErr
            },
            1, &eventType, selfPtr, &handler
        )
    }

    private func pressed(position: Int) {
        let profiles = store.configuration.profiles
        guard profiles.indices.contains(position - 1) else { return }
        store.activate(profileID: profiles[position - 1].id)
    }
}
