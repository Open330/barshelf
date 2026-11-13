import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class MenuBarChartRecorderTests: XCTestCase {
    private var url: URL!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chart-recorder-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("menu-bar-charts.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A recorder on the temp file, with `sensitive` as the widgets that must
    /// stay off disk.
    private func recorder(sensitive: Set<String> = []) -> MenuBarChartRecorder {
        let recorder = MenuBarChartRecorder(fileURL: url)
        recorder.sensitiveWidgetIDs = { sensitive }
        return recorder
    }

    private func entry(_ id: String, _ value: Double) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: id, name: "CPU", prefix: "CPU", style: .stacked, label: "\(Int(value))%",
            metrics: [StatusMetric(id: "cpu", label: "CPU", value: "\(Int(value))%", number: value, format: "percent")],
            separate: true, presentation: MenuBarPresentation(chart: .line)
        )
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func testDefaultsAreTheShippedLocationAndInterval() {
        XCTAssertEqual(MenuBarChartRecorder.defaultSaveInterval, 30)
        XCTAssertEqual(
            Array(MenuBarChartRecorder.defaultFileURL.pathComponents.suffix(2)),
            ["barshelf", "menu-bar-charts.json"]
        )
    }

    func testASampleIsRecordedOnlyForAPendingWidget() {
        let recorder = recorder()

        // A sync with no new reading: nothing recorded, nothing to draw.
        XCTAssertEqual(recorder.charting(entry("w", 10)).history, [])
        XCTAssertNil(recorder.histories["w"])

        recorder.markPending("w")
        let first = recorder.charting(entry("w", 10))
        XCTAssertEqual(first.history, [10])
        XCTAssertEqual(first.chartScale, 100)
        XCTAssertEqual(recorder.histories["w"]?.series, "cpu")

        // The mark is spent: a re-sync, even with another value, adds nothing.
        let recorded = recorder.histories
        XCTAssertEqual(recorder.charting(entry("w", 99)).history, [10])
        XCTAssertEqual(recorder.histories, recorded)

        // Another widget's mark is not this one's.
        recorder.markPending("other")
        _ = recorder.charting(entry("w", 99))
        XCTAssertEqual(recorder.histories, recorded)

        // A new mark takes the reading in: as the step's peak or as a point,
        // depending on how long this test has been running.
        recorder.markPending("w")
        _ = recorder.charting(entry("w", 99))
        XCTAssertNotEqual(recorder.histories["w"], recorded["w"])
        let taken = recorder.histories["w"]
        XCTAssertEqual((taken?.values ?? []) + [taken?.pending].compactMap { $0 }, [10, 99])
    }

    func testAPendingWidgetWithoutANumericReadingRecordsNothing() {
        let recorder = recorder()
        recorder.markPending("t")
        let text = MenuBarEntry(widgetID: "t", name: "T", label: "hi")
        XCTAssertEqual(recorder.charting(text).history, [])
        XCTAssertTrue(recorder.histories.isEmpty)
    }

    func testPruningKeepsChartingWidgetsAndThoseTheCallerKeeps() {
        let recorder = recorder()
        for id in ["charting", "unrendered", "gone"] {
            recorder.markPending(id)
            _ = recorder.charting(entry(id, 10))
        }

        var asked: [String] = []
        recorder.prune(charting: ["charting"]) { id in
            asked.append(id)
            return id == "unrendered"
        }

        XCTAssertEqual(Set(recorder.histories.keys), ["charting", "unrendered"])
        XCTAssertEqual(asked.sorted(), ["gone", "unrendered"], "a charting widget is kept without asking")
    }

    func testPruningDropsThePendingMarkOfAWidgetThatNoLongerCharts() {
        let recorder = recorder()
        recorder.markPending("w")

        recorder.prune(charting: []) { _ in true }

        // The mark went with the prune, kept or not: coming back to the bar
        // does not record the reading from before.
        XCTAssertEqual(recorder.charting(entry("w", 10)).history, [])
        XCTAssertTrue(recorder.histories.isEmpty)
    }

    func testASensitiveWidgetsHistoryIsNeverWritten() throws {
        let recorder = recorder(sensitive: ["secret"])
        for id in ["plain", "secret"] {
            recorder.markPending(id)
            _ = recorder.charting(entry(id, 10))
        }

        recorder.save()

        XCTAssertEqual(Set(MenuBarChartHistoryStore.load(from: url).keys), ["plain"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("secret"))
        // Still drawn: only the file leaves it out.
        XCTAssertNotNil(recorder.histories["secret"])
    }

    func testOnlySensitiveHistoriesWriteNoFile() {
        let recorder = recorder(sensitive: ["secret"])
        recorder.markPending("secret")
        _ = recorder.charting(entry("secret", 10))

        recorder.save()

        XCTAssertFalse(fileExists)
    }

    func testWithNobodyToAskWhatIsSensitiveNothingIsWritten() {
        let recorder = MenuBarChartRecorder(fileURL: url)
        recorder.markPending("w")
        _ = recorder.charting(entry("w", 10))

        recorder.save()

        XCTAssertFalse(fileExists)
    }

    func testAnUnchangedHistoryIsNotRewritten() throws {
        let recorder = recorder()
        recorder.markPending("w")
        _ = recorder.charting(entry("w", 10))
        recorder.save()
        XCTAssertTrue(fileExists)

        // Had the second save written, the file would be back.
        try FileManager.default.removeItem(at: url)
        _ = recorder.charting(entry("w", 10)) // a plain re-sync changes nothing
        recorder.save()
        XCTAssertFalse(fileExists)

        recorder.markPending("w")
        _ = recorder.charting(entry("w", 20))
        recorder.save()
        XCTAssertTrue(fileExists, "a changed history is written again")
    }

    func testAFailedSaveIsRetried() throws {
        let recorder = recorder()
        recorder.markPending("w")
        _ = recorder.charting(entry("w", 10))
        // A file where the directory should be: the write cannot succeed.
        let directory = url.deletingLastPathComponent()
        try Data().write(to: directory)

        recorder.save()
        XCTAssertFalse(fileExists)

        try FileManager.default.removeItem(at: directory)
        recorder.save()
        XCTAssertTrue(fileExists, "the same history is still unsaved, so it is written now")
    }

    func testHistoriesRoundTripThroughTheFile() {
        let first = recorder()
        first.markPending("w")
        _ = first.charting(entry("w", 42))
        first.markPending("w")
        _ = first.charting(entry("w", 50))
        first.save()

        let second = recorder()
        XCTAssertTrue(second.histories.isEmpty, "nothing is read before restore()")
        second.restore()

        // Same format the store has always read and written; the unfinished
        // step's peak is saved as a point.
        XCTAssertEqual(second.histories, MenuBarChartHistoryStore.load(from: url))
        XCTAssertEqual(second.histories["w"]?.values, [42, 50])
        XCTAssertEqual(second.histories["w"]?.series, "cpu")
        XCTAssertEqual(second.histories["w"]?.scale, 100)
        XCTAssertEqual(second.charting(entry("w", 60)).history, [42, 50])
    }

    func testRestoringAMissingOrUnreadableFileIsNoHistory() throws {
        let recorder = recorder()
        recorder.restore()
        XCTAssertTrue(recorder.histories.isEmpty)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)
        recorder.restore()
        XCTAssertTrue(recorder.histories.isEmpty)
    }

    func testTheSaverRunsOnlyWhileThereIsHistory() {
        let recorder = recorder()
        recorder.updateSaver()
        XCTAssertFalse(recorder.isSaving)
        XCTAssertFalse(fileExists, "with nothing recorded and nothing saved there is nothing to write")

        recorder.markPending("w")
        _ = recorder.charting(entry("w", 10))
        recorder.updateSaver()
        XCTAssertTrue(recorder.isSaving)
        XCTAssertFalse(fileExists, "starting the saver does not itself save")
        recorder.updateSaver()
        XCTAssertTrue(recorder.isSaving)

        recorder.save()
        XCTAssertTrue(fileExists)

        // The last charting widget goes: the saver stops, and its one last
        // save has nothing to keep, which removes the file.
        recorder.prune(charting: []) { _ in false }
        recorder.updateSaver()
        XCTAssertFalse(recorder.isSaving)
        XCTAssertFalse(fileExists)
    }

    func testARestoredHistoryStartsTheSaver() {
        let first = recorder()
        first.markPending("w")
        _ = first.charting(entry("w", 10))
        first.save()

        let second = recorder()
        second.restore()
        second.updateSaver()
        XCTAssertTrue(second.isSaving)

        second.prune(charting: []) { _ in false }
        second.updateSaver()
        XCTAssertFalse(second.isSaving)
    }

    /// A history read back at launch and pruned away before anything new was
    /// saved must not leave last run's file behind.
    func testARestoredHistoryThatIsPrunedAwayRemovesItsFile() {
        let first = recorder()
        first.markPending("gone")
        _ = first.charting(entry("gone", 10))
        first.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let second = recorder()
        second.restore()
        XCTAssertNotNil(second.histories["gone"])
        second.prune(charting: []) { _ in false }
        second.updateSaver()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A widget that turns sensitive after its points were saved: the next
    /// save takes them off the disk.
    func testAWidgetThatTurnsSensitiveLeavesTheFileAtTheNextSave() throws {
        var sensitive: Set<String> = []
        let recorder = MenuBarChartRecorder(fileURL: url)
        recorder.sensitiveWidgetIDs = { sensitive }
        for id in ["plain", "later"] {
            recorder.markPending(id)
            _ = recorder.charting(entry(id, 10))
        }
        recorder.save()
        XCTAssertEqual(Set(MenuBarChartHistoryStore.load(from: url).keys), ["plain", "later"])

        sensitive = ["later"]
        recorder.save()
        XCTAssertEqual(Set(MenuBarChartHistoryStore.load(from: url).keys), ["plain"])
    }
}
