import Foundation

/// Global shortcuts BarShelf's own features have claimed, so two of them do
/// not fight over one key. Carbon refuses a second registration of a
/// combination, and Automation stopped its whole script when one of its keys
/// was already a dock profile key.
///
/// The user's Automation script wins: while it runs, the dock leaves its keys
/// alone and shows them as taken.
@MainActor
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
    /// Held by whoever observes; the handler stops being called once this
    /// is released. A token rather than a "remove" call, because the usual
    /// place to remove an observer is a deinit, which is not on the main
    /// actor and so cannot call back into this object.
    package final class Observation {}

    private var observers: [(token: () -> Observation?, handler: () -> Void)] = []

    /// Automation is about to register these (or, with none, has stopped).
    /// Observers run synchronously, so a key the dock held is free by the
    /// time this returns.
    package func setAutomationKeys(_ keys: Set<Key>) {
        guard keys != automation else { return }
        automation = keys
        observers.removeAll { $0.token() == nil }
        observers.forEach { $0.handler() }
    }

    /// Calls `handler` on each change for as long as the result is kept.
    package func observe(_ handler: @escaping () -> Void) -> Observation {
        let observation = Observation()
        observers.append((token: { [weak observation] in observation }, handler: handler))
        return observation
    }
}
