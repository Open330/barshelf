import Carbon.HIToolbox
import Combine
import Foundation
import MenubucketCore

/// ⌃⌥1…9: switch to the first nine dock profiles (R15). Carbon hot keys, like
/// the popup shortcut, so no Accessibility permission is needed. Its own
/// signature keeps its presses apart from the popup shortcut's handler.
/// Which ⌃⌥ numbers another shortcut already owns — another app, or an
/// Automation shortcut — for settings to show. Positions are 1-based.
final class DockHotkeyStatus: ObservableObject {
    static let shared = DockHotkeyStatus()
    @Published fileprivate(set) var unavailable: Set<Int> = []
}

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
    private var registeredCount = 0
    private var unavailable: Set<Int> = [] {
        didSet { DockHotkeyStatus.shared.unavailable = unavailable }
    }
    private var cancellable: AnyCancellable?

    init(store: DockStore) {
        self.store = store
        cancellable = store.$configuration
            .map { $0.profileHotkeysEnabled ? min($0.profiles.count, DockConfiguration.hotkeyProfileLimit) : 0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.register(count: count) }
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Shown in settings beside each profile: "⌃⌥1".
    static func label(forPosition position: Int) -> String? {
        guard (1...DockConfiguration.hotkeyProfileLimit).contains(position) else { return nil }
        return "⌃⌥\(position)"
    }

    private func register(count: Int) {
        // Same count and nothing failed last time: nothing to do. A failure
        // is retried, since whatever held the key may have let it go.
        guard count != registeredCount || !unavailable.isEmpty else { return }
        unregisterAll()
        guard count > 0 else { return }
        installHandlerIfNeeded()
        var failed: Set<Int> = []
        for (index, keyCode) in Self.digitKeyCodes.prefix(count).enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            if RegisterEventHotKey(keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            } else {
                failed.insert(index + 1)
            }
        }
        registeredCount = count
        unavailable = failed
    }



    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        registeredCount = 0
        unavailable = []
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
