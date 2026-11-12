import Foundation

/// Global shortcuts BarShelf's own features have claimed, so two of them do
/// not fight over one key. Carbon refuses a second registration of a
/// combination, and Automation stopped its whole script when one of its keys
/// was already a dock profile key.
///
/// The user's Automation script wins: while it runs, the dock leaves its keys
/// alone and shows them as taken.
package final class InAppHotkeys {
    package static let shared = InAppHotkeys()

    package struct Key: Hashable {
        package let keyCode: UInt32
        package let modifiers: UInt32

        package init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }
    }

    package private(set) var automation: Set<Key> = []
    private var observers: [UUID: () -> Void] = [:]

    /// Automation is about to register these (or, with none, has stopped).
    /// Observers run synchronously, so a key the dock held is free by the
    /// time this returns.
    package func setAutomationKeys(_ keys: Set<Key>) {
        guard keys != automation else { return }
        automation = keys
        observers.values.forEach { $0() }
    }

    @discardableResult
    package func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    package func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}
