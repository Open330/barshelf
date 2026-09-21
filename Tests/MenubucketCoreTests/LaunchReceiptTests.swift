import XCTest
@testable import MenubucketCore

/// The signal that separates a running app from a process that merely exists.
final class LaunchReceiptTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("receipt-tests-\(UUID().uuidString)")
            .appendingPathComponent("launch-receipt.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testAReceiptSurvivesARoundTrip() throws {
        let written = try XCTUnwrap(LaunchReceiptStore.write(
            version: "0.3.2", bundlePath: "/Applications/BarShelf.app",
            pid: 4242, at: Date(timeIntervalSince1970: 1_700_000_000), to: url
        ))
        let read = try XCTUnwrap(LaunchReceiptStore.read(from: url))
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.pid, 4242)
        XCTAssertEqual(read.version, "0.3.2")
    }

    /// The value `write` hands back has to equal the one `read` returns, or a
    /// wait comparing them would treat the old receipt as a fresh launch.
    func testWhatIsWrittenEqualsWhatIsReadBack() throws {
        let written = try XCTUnwrap(
            LaunchReceiptStore.write(version: "0.3.2", bundlePath: nil, pid: 7, to: url)
        )
        XCTAssertEqual(LaunchReceiptStore.read(from: url), written)
    }

    func testWritingCreatesTheDirectoryAndNeverThrows() {
        XCTAssertNotNil(LaunchReceiptStore.write(version: "1.0", bundlePath: nil, to: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// A path the app cannot write to must not take the launch down with it:
    /// a missing receipt reads as "did not start", which leaves the previous
    /// build running rather than quitting into nothing.
    func testAnUnwritableLocationYieldsNilRatherThanThrowing() {
        let blocked = URL(fileURLWithPath: "/System/barshelf/launch-receipt.json")
        XCTAssertNil(LaunchReceiptStore.write(version: "1.0", bundlePath: nil, to: blocked))
        XCTAssertNil(LaunchReceiptStore.read(from: blocked))
    }

    func testMissingOrCorruptReceiptsReadAsNil() throws {
        XCTAssertNil(LaunchReceiptStore.read(from: url))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(LaunchReceiptStore.read(from: url))
    }

    // MARK: - Waiting

    func testTheWaitReturnsTheReplacementsReceipt() {
        let previous = LaunchReceiptStore.write(version: "0.3.1", bundlePath: nil, pid: 1, to: url)
        var ticks = 0
        let found = LaunchReceiptStore.waitForRelaunch(
            replacing: previous, timeout: 10, pollInterval: 0,
            url: url,
            sleep: { _ in
                ticks += 1
                // The replacement announces itself on the third poll.
                if ticks == 3 {
                    LaunchReceiptStore.write(
                        version: "0.3.2", bundlePath: nil, pid: 2, to: self.url
                    )
                }
            }
        )
        XCTAssertEqual(found?.pid, 2)
        XCTAssertEqual(found?.version, "0.3.2")
    }

    /// The case that started all this: the process exists, so a pid check would
    /// pass, but it never runs and never writes a receipt.
    func testAnUnchangedReceiptIsNotAccountedALaunch() {
        let previous = LaunchReceiptStore.write(version: "0.3.1", bundlePath: nil, pid: 1, to: url)
        var clock = Date(timeIntervalSince1970: 0)
        let found = LaunchReceiptStore.waitForRelaunch(
            replacing: previous, timeout: 5, pollInterval: 1, url: url,
            now: { clock },
            sleep: { clock = clock.addingTimeInterval($0) }
        )
        XCTAssertNil(found, "a stale receipt must not read as a fresh launch")
    }

    func testAFirstEverLaunchCountsWhenThereWasNoPreviousReceipt() {
        var ticks = 0
        let found = LaunchReceiptStore.waitForRelaunch(
            replacing: nil, timeout: 10, pollInterval: 0, url: url,
            sleep: { _ in
                ticks += 1
                if ticks == 2 {
                    LaunchReceiptStore.write(version: "0.3.2", bundlePath: nil, pid: 9, to: self.url)
                }
            }
        )
        XCTAssertEqual(found?.pid, 9)
    }

    /// The wait must not depend on the wall clock moving forward: a clock that
    /// steps backwards between the two reads would make a real launch look like
    /// it never happened if this compared timestamps.
    func testALaunchIsRecognisedEvenWhenTheClockStepsBackwards() {
        let previous = LaunchReceiptStore.write(
            version: "0.3.1", bundlePath: nil, pid: 1,
            at: Date(timeIntervalSince1970: 2_000_000_000), to: url
        )
        var ticks = 0
        let found = LaunchReceiptStore.waitForRelaunch(
            replacing: previous, timeout: 10, pollInterval: 0, url: url,
            sleep: { _ in
                ticks += 1
                if ticks == 2 {
                    LaunchReceiptStore.write(
                        version: "0.3.2", bundlePath: nil, pid: 2,
                        at: Date(timeIntervalSince1970: 1_000_000_000), to: self.url
                    )
                }
            }
        )
        XCTAssertEqual(found?.pid, 2)
    }

    func testTheDefaultLocationSitsBesideTheOtherAppState() {
        XCTAssertTrue(
            LaunchReceiptStore.defaultURL.path.hasSuffix(
                "Application Support/barshelf/launch-receipt.json"
            ),
            LaunchReceiptStore.defaultURL.path
        )
    }
}
