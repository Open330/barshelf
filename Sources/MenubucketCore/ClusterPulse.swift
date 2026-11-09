import Foundation

/// The wave that runs through the cluster when a chip's state changes: each
/// chip in turn, left to right, comes to the front, grows, and settles.
///
/// Every chip takes part, not only the one that changed. System readings
/// change all the time, and one chip jumping on its own reads as a glitch;
/// a wave across the whole cluster reads as "something here changed".
///
/// What counts as a change is the chip's state (`ClusterChip.pulseState`),
/// not its number: a CPU reading that moves every five seconds never sets it
/// off, a reading turning to a warning does. Waves are at least `cooldown`
/// apart; changes in between are held for one wave when it ends.
public enum ClusterPulse {
    /// Between one chip's start and the next's.
    public static let stagger: TimeInterval = 0.09
    /// One chip's rise and settle.
    public static let chipDuration: TimeInterval = 0.56
    /// The shortest time between two waves.
    public static let cooldown: TimeInterval = 180
    /// How much a chip grows at the top of its rise.
    public static let growth: Double = 0.22
    /// The share of `chipDuration` spent rising.
    static let rise: Double = 0.3

    /// The whole wave across `count` chips.
    public static func duration(count: Int) -> TimeInterval {
        stagger * Double(max(count - 1, 0)) + chipDuration
    }

    /// How far chip `index` is through its rise, 0 (resting) to 1 (top),
    /// `elapsed` seconds into the wave.
    public static func lift(index: Int, elapsed: TimeInterval) -> Double {
        let t = (elapsed - stagger * Double(index)) / chipDuration
        guard t > 0, t < 1 else { return 0 }
        if t < rise {
            let u = t / rise
            return 1 - pow(1 - u, 3)
        }
        let u = (t - rise) / (1 - rise)
        // Ease in and out on the way down.
        return 1 - (u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
    }

    /// The chips whose state changed, by id. Chips that came or went are
    /// not changes: the cluster redraws from scratch for those.
    public static func changes(from old: [ClusterChip], to new: [ClusterChip]) -> Set<String> {
        let before = Dictionary(old.map { ($0.id, $0.pulseState) }, uniquingKeysWith: { first, _ in first })
        return Set(new.compactMap { chip in
            guard let state = before[chip.id], state != chip.pulseState else { return nil }
            return chip.id
        })
    }
}

/// When the next wave may run.
public struct ClusterPulseGate: Equatable, Sendable {
    public private(set) var lastWave: Date?
    /// Changes seen while a wave could not run, waiting for the next.
    public private(set) var pending: Set<String> = []
    /// Each chip's state as of the last wave, or as first seen: what a
    /// held change is measured against when its wave comes.
    public private(set) var settled: [String: ClusterChip.PulseState] = [:]

    public init() {}

    public enum Decision: Equatable, Sendable {
        /// Run a wave now.
        case now
        /// Hold until this time, then run one.
        case at(Date)
        /// Nothing to do.
        case none
    }

    /// Records `changes` and says when to run a wave for them.
    public mutating func note(_ changes: Set<String>, now: Date) -> Decision {
        pending.formUnion(changes)
        guard !pending.isEmpty else { return .none }
        if let lastWave, now.timeIntervalSince(lastWave) < ClusterPulse.cooldown {
            return .at(lastWave.addingTimeInterval(ClusterPulse.cooldown))
        }
        return .now
    }

    /// The held changes that still stand in `chips`. A chip that turned to
    /// a warning and back while the wave was held has nothing to show: a
    /// spike that came and went set off a wave three minutes later, every
    /// three minutes.
    public func standing(in chips: [ClusterChip]) -> Set<String> {
        let current = Dictionary(chips.map { ($0.id, $0.pulseState) }, uniquingKeysWith: { first, _ in first })
        return pending.filter { id in
            guard let state = current[id] else { return false }
            return settled[id] != state
        }
    }

    /// A wave ran (or was skipped on purpose) over `chips`: start the
    /// cooldown, drop what it covered, and measure later changes from here.
    public mutating func ran(at now: Date, chips: [ClusterChip]) {
        lastWave = now
        pending = []
        settle(chips)
    }

    /// Held changes that all went back: nothing to show, no cooldown.
    public mutating func dropReverted() { pending = [] }

    /// Forget held changes and measure from `chips`, e.g. when the chips
    /// are replaced.
    public mutating func reset(settling chips: [ClusterChip] = []) {
        pending = []
        settle(chips)
    }

    private mutating func settle(_ chips: [ClusterChip]) {
        settled = Dictionary(chips.map { ($0.id, $0.pulseState) }, uniquingKeysWith: { first, _ in first })
    }
}

extension ClusterChip {
    /// What a wave answers to: the reading's colour and alert, its icon,
    /// whether it has a value, and an on/off reading. Not the number itself.
    public struct PulseState: Equatable, Sendable {
        var tint: MenuBarTint?
        var alert: Bool
        var symbol: String?
        var initial: String
        var hasValue: Bool
        var activity: String?
    }

    public var pulseState: PulseState {
        PulseState(
            tint: tint, alert: alert, symbol: symbol, initial: initial,
            hasValue: !value.isEmpty,
            activity: value == "●" || value == "○" ? value : nil
        )
    }
}
