import Foundation

/// Ownership of asynchronous exec/workflow results across reloads. An old
/// completion cannot release a newer refresh's slot or publish old settings.
///
/// Generations are per widget: a reload outdates only the widgets whose
/// configuration changed. Outdating every widget on any reload threw away
/// each in-flight result and ran its command again, and a widget writing
/// into a watched folder could keep that going in a loop.
struct NativeRefreshGate {
    struct Token: Equatable {
        let generation: UInt
        let serial: UInt
    }
    enum Completion: Equatable { case current, staleConfiguration, superseded }
    private var generations: [String: UInt] = [:]
    private var serial: UInt = 0
    private var active: [String: Token] = [:]

    mutating func begin(_ id: String) -> Token {
        serial &+= 1
        let token = Token(generation: generations[id, default: 0], serial: serial)
        active[id] = token
        return token
    }

    /// `changed` are the kept widgets whose configuration is new; their
    /// in-flight results are outdated. Others' results stay good.
    mutating func reload(keeping ids: Set<String>, changed: Set<String>) {
        for id in changed where ids.contains(id) { generations[id, default: 0] &+= 1 }
        generations = generations.filter { ids.contains($0.key) }
        active = active.filter { ids.contains($0.key) }
    }

    mutating func cancel(_ id: String) { active.removeValue(forKey: id) }

    func isCurrent(_ id: String, token: Token) -> Bool {
        active[id] == token && token.generation == generations[id, default: 0]
    }

    mutating func finish(_ id: String, token: Token) -> Completion {
        guard active[id] == token else { return .superseded }
        active.removeValue(forKey: id)
        return token.generation == generations[id, default: 0] ? .current : .staleConfiguration
    }
}
