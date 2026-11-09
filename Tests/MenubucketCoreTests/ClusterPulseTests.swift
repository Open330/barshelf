import XCTest
@testable import MenubucketCore

/// Telling chips apart (symbols, tone steps) and the update wave.
final class ClusterPulseTests: XCTestCase {
    // MARK: - Symbols

    func testReadingLabelsPickASymbol() {
        XCTAssertEqual(MenuBarClusterPolicy.metricSymbol(for: ["CPU"]), "cpu")
        XCTAssertEqual(MenuBarClusterPolicy.metricSymbol(for: ["RAM"]), "memorychip")
        XCTAssertEqual(MenuBarClusterPolicy.metricSymbol(for: ["Memory used"]), "memorychip")
        XCTAssertEqual(MenuBarClusterPolicy.metricSymbol(for: ["PWR"]), "bolt.fill")
        XCTAssertEqual(MenuBarClusterPolicy.metricSymbol(for: ["", "fan-1"]), "fan")
        XCTAssertNil(MenuBarClusterPolicy.metricSymbol(for: ["Remember"]), "whole words only")
        XCTAssertNil(MenuBarClusterPolicy.metricSymbol(for: ["", "work-01"]))
    }

    func testTextOnlyWidgetsOfOneKindGetTheirReadingsSymbol() {
        // Two copies of the System widget, CPU and RAM: same name, same icon.
        let entries = [
            MenuBarEntry(widgetID: "system", name: "System",
                         metrics: [StatusMetric(label: "CPU", value: "17%", number: 17, unit: "%")]),
            MenuBarEntry(widgetID: "system--ram", name: "System",
                         metrics: [StatusMetric(label: "RAM", value: "78%", number: 78, unit: "%")]),
            MenuBarEntry(widgetID: "sensors", name: "Sensors", prefix: "PWR",
                         metrics: [StatusMetric(label: "", value: "6W")]),
        ].map { entry -> MenuBarEntry in
            var entry = entry
            entry.iconSymbol = "cpu.fill"
            return entry
        }
        let chips = MenuBarClusterPolicy.chips(from: entries)
        XCTAssertEqual(chips.map(\.symbol), ["cpu", "memorychip", "bolt.fill"])

        // Without SF Symbols the reading's initial, not the widget's.
        let plain = MenuBarClusterPolicy.chips(from: entries) { _ in false }
        XCTAssertEqual(plain.map(\.initial), ["C", "R", "P"])
    }

    func testTheWidgetsOwnIconWhenTheReadingNamesNothing() {
        var entry = MenuBarEntry(widgetID: "aas", name: "aas usage", label: "6% left")
        entry.iconSymbol = "gauge"
        XCTAssertEqual(MenuBarClusterPolicy.chips(from: [entry]).first?.symbol, "gauge")
    }

    func testTheShownIconAndTheUsersChoiceStillWin() {
        let shown = MenuBarEntry(widgetID: "b", name: "Battery", symbol: "battery.100",
                                 metrics: [StatusMetric(label: "CPU", value: "1%")])
        XCTAssertEqual(MenuBarClusterPolicy.chips(from: [shown]).first?.symbol, "battery.100")
        let emoji = MenuBarEntry(widgetID: "k", name: "k8s", iconOverride: "🚢",
                                 metrics: [StatusMetric(label: "CPU", value: "1%")])
        let chip = MenuBarClusterPolicy.chips(from: [emoji]) { $0 != "🚢" }.first
        XCTAssertNil(chip?.symbol)
        XCTAssertEqual(chip?.initial, "🚢")
    }

    func testProfileChipsTakeTheirLabelsSymbol() {
        var entry = MenuBarEntry(widgetID: "sys", name: "System", metrics: [
            StatusMetric(label: "CPU", value: "1%"), StatusMetric(label: "RAM", value: "2%"),
        ])
        entry.profiles = true
        XCTAssertEqual(MenuBarClusterPolicy.chips(from: [entry]).map(\.symbol), ["cpu", "memorychip"])
    }

    // MARK: - Tones

    func testChipsSharingAColourStepApart() {
        XCTAssertEqual(MenuBarClusterPolicy.toneSteps(keys: ["p", "p", "o", "o", "p"]), [0, 1, 0, 1, 2])
        XCTAssertEqual(MenuBarClusterPolicy.toneSteps(keys: ["a", "b", "c"]), [0, 0, 0])
    }

    // MARK: - Wave

    func testEachChipRisesInTurnAndSettles() {
        XCTAssertEqual(ClusterPulse.lift(index: 0, elapsed: 0), 0)
        let top = ClusterPulse.chipDuration * ClusterPulse.rise
        XCTAssertEqual(ClusterPulse.lift(index: 0, elapsed: top), 1, accuracy: 0.001)
        XCTAssertEqual(ClusterPulse.lift(index: 2, elapsed: 2 * ClusterPulse.stagger + top), 1, accuracy: 0.001)
        // Chip 2 has not started while chip 0 is at its top.
        XCTAssertEqual(ClusterPulse.lift(index: 2, elapsed: top - 0.1), 0)
        XCTAssertEqual(ClusterPulse.lift(index: 3, elapsed: ClusterPulse.duration(count: 4)), 0)
        XCTAssertEqual(ClusterPulse.duration(count: 4), 3 * ClusterPulse.stagger + ClusterPulse.chipDuration, accuracy: 1e-9)
        // Never above the top.
        for step in 0...100 {
            let lift = ClusterPulse.lift(index: 1, elapsed: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(lift, 0)
            XCTAssertLessThanOrEqual(lift, 1.0001)
        }
    }

    func testOnlyStateChangesSetItOff() {
        let cpu = ClusterChip(widgetID: "cpu", name: "CPU", initial: "C", reading: "17%")
        let ram = ClusterChip(widgetID: "ram", name: "RAM", initial: "R", reading: "78%")
        var ticked = cpu
        ticked.value = "23%"
        ticked.reading = "23%"
        XCTAssertEqual(ClusterPulse.changes(from: [cpu, ram], to: [ticked, ram]), [], "a number that ticks")

        var warned = ram
        warned.tint = .warning
        XCTAssertEqual(ClusterPulse.changes(from: [cpu, ram], to: [cpu, warned]), ["ram"])

        let awake = ClusterChip(widgetID: "awake", name: "Keep Awake", symbol: "cup.and.saucer", initial: "K")
        var on = awake
        on.symbol = "cup.and.saucer.fill"
        XCTAssertEqual(ClusterPulse.changes(from: [awake], to: [on]), ["awake"])

        var active = cpu
        active.value = "●"
        var idle = cpu
        idle.value = "○"
        XCTAssertEqual(ClusterPulse.changes(from: [active], to: [idle]), ["cpu"])

        XCTAssertEqual(ClusterPulse.changes(from: [cpu], to: [cpu, ram]), [], "a new chip is not a change")
    }

    func testWavesKeepTheirDistance() {
        var gate = ClusterPulseGate()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(gate.note([], now: start), .none)
        XCTAssertEqual(gate.note(["a"], now: start), .now)
        gate.ran(at: start, chips: [])
        XCTAssertTrue(gate.pending.isEmpty)

        let soon = start.addingTimeInterval(30)
        XCTAssertEqual(gate.note(["b"], now: soon), .at(start.addingTimeInterval(ClusterPulse.cooldown)))
        // Held changes add up for the one wave.
        _ = gate.note(["c"], now: soon.addingTimeInterval(10))
        XCTAssertEqual(gate.pending, ["b", "c"])

        let later = start.addingTimeInterval(ClusterPulse.cooldown + 1)
        XCTAssertEqual(gate.note([], now: later), .now, "held changes run once the cooldown is over")
        gate.reset()
        XCTAssertEqual(gate.note([], now: later), .none)
    }

    /// A held change that went back by the time its wave comes is no
    /// change: a CPU spike to a warning and back does not wave three
    /// minutes later.
    func testAHeldChangeThatWentBackDoesNotWave() {
        let cpu = ClusterChip(widgetID: "cpu", name: "CPU", initial: "C", reading: "17%")
        var warned = cpu
        warned.tint = .warning
        let ram = ClusterChip(widgetID: "ram", name: "RAM", initial: "R", reading: "78%")
        var ramAlert = ram
        ramAlert.alert = true

        var gate = ClusterPulseGate()
        gate.reset(settling: [cpu, ram])
        let start = Date(timeIntervalSince1970: 1000)
        gate.ran(at: start, chips: [cpu, ram])
        _ = gate.note(ClusterPulse.changes(from: [cpu, ram], to: [warned, ram]), now: start.addingTimeInterval(20))
        _ = gate.note(ClusterPulse.changes(from: [warned, ram], to: [cpu, ram]), now: start.addingTimeInterval(25))
        XCTAssertEqual(gate.standing(in: [cpu, ram]), [], "the spike came and went")

        _ = gate.note(ClusterPulse.changes(from: [cpu, ram], to: [cpu, ramAlert]), now: start.addingTimeInterval(30))
        XCTAssertEqual(gate.standing(in: [cpu, ramAlert]), ["ram"], "only what still differs from the last wave")
        gate.ran(at: start.addingTimeInterval(180), chips: [cpu, ramAlert])
        XCTAssertEqual(gate.standing(in: [cpu, ramAlert]), [])
    }

    func testThePreferenceDefaultsOnAndSurvivesOldFiles() throws {
        XCTAssertTrue(AppPreferences().menuBarPulse)
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.menuBarPulse)
        var off = AppPreferences()
        off.menuBarPulse = false
        let round = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(round.menuBarPulse)
    }
}
