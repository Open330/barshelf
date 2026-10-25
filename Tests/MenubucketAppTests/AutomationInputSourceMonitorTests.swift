import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class AutomationInputSourceMonitorTests: XCTestCase {
    private final class Job {
        let delay: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(_ delay: TimeInterval, _ action: @escaping () -> Void) { self.delay = delay; self.action = action }
    }
    private final class Fixture {
        var settings: AutomationInputSource.SystemSettings = .available([
            "61": ["enabled": true, "value": ["parameters": [65535, 79, 8388608]]]
        ])
        var context = AutomationInputSourceMonitor.Context(sourceID: "ABC", applicationPID: 12)
        var relayCount = 0
        var directCount = 0
        var failSend = false
        var jobs: [Job] = []
        var states: [AutomationInputSource.Status] = []
        lazy var monitor = AutomationInputSourceMonitor(
            readSettings: { self.settings }, context: { self.context },
            relay: { _ in
                self.relayCount += 1
                if self.failSend { throw AutomationFailure("send failed") }
            }, direct: { self.directCount += 1 },
            schedule: { delay, action in
                let job = Job(delay, action)
                self.jobs.append(job)
                return { job.cancelled = true }
            }, report: { self.states.append($0) })
    }

    /// No table is what an uncustomized Mac returns (and a preferences
    /// service that answered nothing). ⌘Space still switches, directly, and
    /// the outcome says direct selection is limited: never silent, never dead.
    func testMissingSettingsSwitchDirectlyAndSayItIsLimited() throws {
        let f = Fixture()
        f.settings = AutomationInputSource.settings(from: nil)
        if case .missing = f.settings {} else { XCTFail("no table must read as missing") }
        try f.monitor.selectNext()
        XCTAssertEqual(f.relayCount, 0)
        XCTAssertEqual(f.directCount, 1)
        f.context = .init(sourceID: "Korean", applicationPID: 12)
        f.jobs[0].action()
        XCTAssertEqual(f.states, [.checking, .needsAttention(AutomationInputSourceMonitor.directSelectionLimited)])
    }

    func testUnreadableSettingsDoesNotSilentlySelectDirectlyOrSendAKey() {
        let f = Fixture()
        f.settings = AutomationInputSource.settings(from: "malformed")
        XCTAssertThrowsError(try f.monitor.selectNext())
        XCTAssertEqual(f.relayCount, 0)
        XCTAssertEqual(f.directCount, 0)
        XCTAssertTrue(f.jobs.isEmpty)
        XCTAssertEqual(f.states, [.needsAttention(AutomationInputSourceMonitor.settingsUnavailable)])
    }

    /// The setup ⌘Space depends on, as cfprefsd hands it over: `enabled` a
    /// CFBoolean, the parameters plain numbers. It must parse and relay F18
    /// with only the fn flag.
    func testTheRealF18ShortcutParsesAndRelays() throws {
        let entry: [String: Any] = [
            "enabled": kCFBooleanTrue as Any,
            "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: 79), NSNumber(value: 8_388_608)],
                      "type": "standard"],
        ]
        for enabled in [kCFBooleanTrue as Any, NSNumber(value: 1)] {
            var table: [String: Any] = ["61": entry, "60": ["enabled": kCFBooleanFalse as Any]]
            var copy = entry; copy["enabled"] = enabled; table["61"] = copy
            guard case let .available(parsed) = AutomationInputSource.settings(from: table) else {
                return XCTFail("the real F18 setup was rejected")
            }
            XCTAssertEqual(AutomationInputSource.systemTrigger(in: parsed),
                           .init(keyCode: 79, flags: .maskSecondaryFn))
        }
    }

    /// On a Mac that has the shortcut table, its real contents must not be
    /// refused: that would stop ⌘Space outright. Skipped where there is none.
    func testThisMacsShortcutTableIsAccepted() throws {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain)
        try XCTSkipIf(value == nil, "no symbolic hot key table on this Mac")
        if case .unavailable = AutomationInputSource.settings(from: value) {
            XCTFail("this Mac's real shortcut table was refused")
        }
    }

    func testMalformedEnabledShortcutNeverFallsThroughToDirectSelection() {
        let invalid: [[String: Any]] = [
            ["61": "malformed"],
            ["61": ["value": ["parameters": [65535, 79, 8388608]]]],
            ["61": ["enabled": true]],
            ["61": ["enabled": true, "value": ["parameters": []]]],
            ["61": ["enabled": true, "value": ["parameters": ["65535", "79", "8388608"]]]],
            ["61": ["enabled": true, "value": ["parameters": [65535, -1, 0]]]],
            ["61": ["enabled": true, "value": ["parameters": [65535, 79, -1]]]],
            ["61": ["enabled": true, "value": ["parameters": [65535, true, 0]]]]
        ]
        for table in invalid {
            let f = Fixture()
            f.settings = AutomationInputSource.settings(from: table)
            XCTAssertThrowsError(try f.monitor.selectNext())
            XCTAssertEqual(f.relayCount, 0)
            XCTAssertEqual(f.directCount, 0)
            XCTAssertTrue(f.jobs.isEmpty)
            XCTAssertEqual(f.states, [.needsAttention(AutomationInputSourceMonitor.settingsUnavailable)])
        }
    }

    func testObservedRelayChangeClearsPendingChecksWithoutRetry() throws {
        let f = Fixture()
        try f.monitor.selectNext()
        XCTAssertEqual(f.states, [.checking])
        XCTAssertEqual(f.jobs.map(\.delay), [0.05, 0.15, 0.4])
        f.context = .init(sourceID: "Korean", applicationPID: 12)
        f.jobs[0].action()
        XCTAssertEqual(f.states, [.checking, .changed])
        XCTAssertTrue(f.jobs.allSatisfy(\.cancelled))
        f.jobs[2].action() // A dispatched stale callback must be harmless.
        XCTAssertEqual(f.states, [.checking, .changed])
        XCTAssertEqual(f.relayCount, 1)
        XCTAssertEqual(f.directCount, 0)
    }

    func testUnchangedSourceWarnsOnlyAtDeadlineAndNeverRetriesOrFallsBack() throws {
        let f = Fixture()
        try f.monitor.selectNext()
        f.jobs[0].action()
        f.jobs[1].action()
        XCTAssertEqual(f.states, [.checking])
        f.jobs[2].action()
        XCTAssertEqual(f.states.last, .needsAttention(AutomationInputSourceMonitor.noChangeDetected))
        XCTAssertEqual(f.relayCount, 1)
        XCTAssertEqual(f.directCount, 0)
        XCTAssertTrue(f.jobs.allSatisfy(\.cancelled))
    }

    func testFocusChangeDoesNotReportAnotherAppsRememberedSourceAsSuccess() throws {
        let f = Fixture()
        try f.monitor.selectNext()
        f.context = .init(sourceID: "Korean", applicationPID: 99)
        f.jobs[0].action()
        XCTAssertEqual(f.states, [.checking, .idle])
        XCTAssertTrue(f.jobs.allSatisfy(\.cancelled))
    }

    func testAReplacedRequestCannotBeFailedOrClearedByEarlierCallbacks() throws {
        let f = Fixture()
        try f.monitor.selectNext()
        let old = f.jobs
        f.context = .init(sourceID: "Korean", applicationPID: 12)
        try f.monitor.selectNext()
        XCTAssertTrue(old.allSatisfy(\.cancelled))
        old.forEach { $0.action() }
        XCTAssertEqual(f.states, [.checking, .checking])
        f.context = .init(sourceID: "ABC", applicationPID: 12)
        f.jobs[3].action()
        XCTAssertEqual(f.states, [.checking, .checking, .changed])
        XCTAssertEqual(f.relayCount, 2)
        XCTAssertEqual(f.directCount, 0)
    }

    func testStopDropsAllLateOutcomes() throws {
        let f = Fixture()
        try f.monitor.selectNext()
        f.monitor.stop()
        f.jobs.forEach { $0.action() }
        XCTAssertEqual(f.states, [.checking])
        XCTAssertTrue(f.jobs.allSatisfy(\.cancelled))
    }

    func testExplicitDisabledAndEmptyTablesRemainDirectWithAnHonestLimitation() throws {
        for table: [String: Any] in [[:], ["61": ["enabled": false, "value": ["parameters": [65535, 79, 8388608]]]]] {
            let f = Fixture()
            f.settings = AutomationInputSource.settings(from: table)
            try f.monitor.selectNext()
            XCTAssertEqual(f.relayCount, 0)
            XCTAssertEqual(f.directCount, 1)
            f.context = .init(sourceID: "Korean", applicationPID: 12)
            f.jobs[0].action()
            XCTAssertEqual(f.states.last, .needsAttention(AutomationInputSourceMonitor.directSelectionLimited))
        }
    }

    func testSendFailureDoesNotScheduleChecksOrRetry() {
        let f = Fixture()
        f.failSend = true
        XCTAssertThrowsError(try f.monitor.selectNext())
        XCTAssertEqual(f.states, [.checking, .needsAttention("send failed")])
        XCTAssertEqual(f.relayCount, 1)
        XCTAssertEqual(f.directCount, 0)
        XCTAssertTrue(f.jobs.isEmpty)
    }

    func testMissingCurrentSourceDoesNotSendAKey() {
        let f = Fixture()
        f.context = .init(sourceID: nil, applicationPID: 12)
        XCTAssertThrowsError(try f.monitor.selectNext())
        XCTAssertEqual(f.states, [.needsAttention(AutomationInputSourceMonitor.sourceUnavailable)])
        XCTAssertEqual(f.relayCount, 0)
        XCTAssertEqual(f.directCount, 0)
    }
}
