import AppKit

/// Main-run-loop input switching. Work exists only after a requested switch;
/// no background timer, automatic retry, settings write or daemon restart.
final class AutomationInputSourceMonitor {
    struct Context: Equatable {
        let sourceID: String?
        let applicationPID: pid_t?

        static func current() -> Context {
            Context(sourceID: AutomationInputSource.currentID,
                    applicationPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
    }

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> (() -> Void)
    private let readSettings: () -> AutomationInputSource.SystemSettings
    private let context: () -> Context
    private let relay: (AutomationInputSource.SystemTrigger) throws -> Void
    private let direct: () throws -> Void
    private let schedule: Schedule
    private let report: (AutomationInputSource.Status) -> Void
    private var pending: UUID?
    private var cancellations: [() -> Void] = []

    init(readSettings: @escaping () -> AutomationInputSource.SystemSettings = AutomationInputSource.currentSystemSettings,
         context: @escaping () -> Context = Context.current,
         relay: @escaping (AutomationInputSource.SystemTrigger) throws -> Void = AutomationInputSource.send,
         direct: @escaping () throws -> Void = AutomationInputSource.selectDirect,
         schedule: @escaping Schedule = AutomationInputSourceMonitor.scheduleOnMain,
         report: @escaping (AutomationInputSource.Status) -> Void) {
        self.readSettings = readSettings
        self.context = context
        self.relay = relay
        self.direct = direct
        self.schedule = schedule
        self.report = report
    }

    func selectNext() throws {
        stop()
        do {
            // A corrupt table is refused: it is not a choice of direct
            // selection. No table at all is what a Mac nobody has customized
            // looks like (and also a preferences service that returned
            // nothing): switching directly keeps ⌘Space working, and the
            // check below still reports direct selection's limitation, so
            // the fallback is never silent.
            let trigger: AutomationInputSource.SystemTrigger?
            switch readSettings() {
            case let .available(table): trigger = AutomationInputSource.systemTrigger(in: table)
            case .missing: trigger = nil
            case .unavailable: throw AutomationFailure(Self.settingsUnavailable)
            }
            let before = context()
            guard before.sourceID != nil else { throw AutomationFailure(Self.sourceUnavailable) }
            report(.checking)
            if let trigger { try relay(trigger) } else { try direct() }
            let request = UUID()
            pending = request
            for delay in [0.05, 0.15, 0.4] {
                cancellations.append(schedule(delay) { [weak self] in
                    self?.check(request: request, before: before, relayed: trigger != nil, final: delay == 0.4)
                })
            }
        } catch {
            stop()
            report(.needsAttention(error.localizedDescription))
            throw AutomationInputSource.ReportedFailure(message: error.localizedDescription)
        }
    }

    private func check(request: UUID, before: Context, relayed: Bool, final: Bool) {
        guard pending == request else { return }
        let after = context()
        // A different app may choose its own remembered source. Do not
        // attribute that change (or absence of change) to our request.
        guard after.applicationPID == before.applicationPID else {
            stop()
            report(.idle)
            return
        }
        if let current = after.sourceID, current != before.sourceID {
            stop()
            report(relayed ? .changed : .needsAttention(Self.directSelectionLimited))
        } else if final {
            stop()
            report(.needsAttention(Self.noChangeDetected))
        }
    }

    func stop() {
        pending = nil
        let work = cancellations
        cancellations.removeAll()
        work.forEach { $0() }
    }

    deinit { cancellations.forEach { $0() } }

    private static func scheduleOnMain(after delay: TimeInterval, action: @escaping () -> Void) -> (() -> Void) {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }

    static var settingsUnavailable: String {
        String(localized: "Couldn’t read macOS input-source shortcut settings. Open Keyboard Shortcuts → Input Sources and check the shortcut. If other system settings are also missing, log out and back in or restart your Mac, then try again.")
    }
    static var sourceUnavailable: String {
        String(localized: "Couldn’t read the current input source. Check Input Sources in System Settings, then try again.")
    }
    static var noChangeDetected: String {
        String(localized: "No input-source change was detected. Check that at least two input sources are enabled and that the system’s Select next source shortcut uses an unused key without modifiers. If the settings look correct, log out and back in or restart your Mac. BarShelf hasn’t retried the switch.")
    }
    static var directSelectionLimited: String {
        String(localized: "Direct input-source selection was requested, but some apps may keep using the previous input language. For reliable switching, assign Select next source in Input menu an unused key without modifiers in Keyboard Shortcuts → Input Sources.")
    }
}
