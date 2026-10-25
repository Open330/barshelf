import XCTest
@testable import MenubucketApp

final class StaleWidgetExtensionTests: XCTestCase {
    private let path = "/Applications/BarShelf.app/Contents/PlugIns/BarShelfWidgets.appex/Contents/MacOS/BarShelfWidgets"
    private let built = Date(timeIntervalSince1970: 1_800_000_000)

    /// The case seen live: an extension started at boot, two weeks before
    /// the installed binary was written, still drawing every desktop widget.
    func testAnExtensionOlderThanItsBinaryIsStale() {
        let processes = [
            StaleWidgetExtension.Process(pid: 804, executable: path, startedAt: built.addingTimeInterval(-14 * 86_400)),
            StaleWidgetExtension.Process(pid: 900, executable: path, startedAt: built.addingTimeInterval(60)),
        ]
        XCTAssertEqual(StaleWidgetExtension.stale(processes, executable: path, builtAt: built), [804])
    }

    /// Another copy of BarShelf (a build folder, a second install) is not
    /// this bundle's extension, however old.
    func testOnlyThisBundlesExtensionIsConsidered() {
        let other = StaleWidgetExtension.Process(
            pid: 77, executable: "/tmp/dist/BarShelf.app/Contents/PlugIns/BarShelfWidgets.appex/Contents/MacOS/BarShelfWidgets",
            startedAt: built.addingTimeInterval(-86_400)
        )
        XCTAssertEqual(StaleWidgetExtension.stale([other], executable: path, builtAt: built), [])
    }

    /// One started in the same second the binary was written is the new one.
    func testAStartWithinASecondOfTheBuildIsNotStale() {
        let fresh = StaleWidgetExtension.Process(pid: 5, executable: path, startedAt: built.addingTimeInterval(-0.5))
        XCTAssertEqual(StaleWidgetExtension.stale([fresh], executable: path, builtAt: built), [])
    }

    /// Measured on 0.7.6→0.7.7: the update unlinked the running extension's
    /// file, `proc_pidpath` failed, and a path-only match left it running.
    func testAnExtensionWhoseFileIsGoneIsStaleWhenOlder() {
        let gone = StaleWidgetExtension.Process(pid: 38557, executable: nil, startedAt: built.addingTimeInterval(-55_000))
        let freshGone = StaleWidgetExtension.Process(pid: 9, executable: nil, startedAt: built.addingTimeInterval(30))
        XCTAssertEqual(StaleWidgetExtension.stale([gone, freshGone], executable: path, builtAt: built), [38557])
    }
}
