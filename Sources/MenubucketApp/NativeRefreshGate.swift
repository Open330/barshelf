import Foundation

/// Ownership of asynchronous exec/workflow results across reloads. An old
/// completion cannot release a newer refresh's slot or publish old settings.
struct NativeRefreshGate {
    struct Token: Equatable {
        let generation: UInt
        let serial: UInt
    }
    enum Completion: Equatable { case current, staleConfiguration, superseded }
    private var generation: UInt = 0
    private var serial: UInt = 0
    private var active: [String: Token] = [:]

    mutating func begin(_ id: String) -> Token {
        serial &+= 1
        let token = Token(generation: generation, serial: serial)
        active[id] = token
        return token
    }

    mutating func reload(keeping ids: Set<String>) {
        generation &+= 1
        active = active.filter { ids.contains($0.key) }
    }

    mutating func cancel(_ id: String) { active.removeValue(forKey: id) }

    func isCurrent(_ id: String, token: Token) -> Bool {
        active[id] == token && token.generation == generation
    }

    mutating func finish(_ id: String, token: Token) -> Completion {
        guard active[id] == token else { return .superseded }
        active.removeValue(forKey: id)
        return token.generation == generation ? .current : .staleConfiguration
    }
}
