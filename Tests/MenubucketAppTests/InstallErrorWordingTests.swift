import XCTest
@testable import MenubucketApp
@testable import MenubucketCore

/// Install failures read as what happened and what to do. Addresses,
/// archive paths and parser output stay out of the sentence (they go to the
/// log and "Copy Details").
final class InstallErrorWordingTests: XCTestCase {
    private let url = URL(string: "https://github.com/someone/widget/archive/main.zip")!

    func testHTTPFailureLeavesTheAddressInDetails() {
        for error: Error in [WidgetInstallFlowError.httpStatus(404, url), HeadlessInstallError.httpStatus(404, url)] {
            let failure = WidgetInstallFlow.explainFailure(error)
            XCTAssertFalse(failure.message.contains("https://"), failure.message)
            XCTAssertFalse(failure.message.lowercased().contains("download failed"))
            XCTAssertTrue(failure.message.contains("404"))
            XCTAssertEqual(failure.detail, "HTTP 404: \(url.absoluteString)")
        }
    }

    func testNoWidgetFoundSaysWhatToCheck() {
        let empty = WidgetInstallFlow.explainFailure(WidgetInstallFlowError.noWidgetsFound(details: []))
        XCTAssertFalse(empty.message.contains("widget.json found"))
        XCTAssertNil(empty.detail)
        let broken = WidgetInstallFlow.explainFailure(
            WidgetInstallFlowError.noWidgetsFound(details: ["weather: invalid widget.json: keyNotFound"]))
        XCTAssertFalse(broken.message.contains("keyNotFound"))
        XCTAssertEqual(broken.detail, "weather: invalid widget.json: keyNotFound")
    }

    func testInsecureAndNetworkFailures() {
        let insecure = WidgetInstallFlow.explainFailure(WidgetInstallFlowError.notHTTP(URL(string: "http://example.com/w.zip")!))
        XCTAssertFalse(insecure.message.contains("non-HTTP"))
        XCTAssertEqual(insecure.detail, "http://example.com/w.zip")
        let offline = WidgetInstallFlow.explainFailure(URLError(.notConnectedToInternet))
        XCTAssertTrue(offline.message.lowercased().contains("internet"), offline.message)
        XCTAssertNotNil(offline.detail)
    }

    func testEveryFailureEndsWithSomethingToDo() {
        let errors: [Error] = [
            WidgetInstallFlowError.noDownloadCandidates,
            WidgetInstallFlowError.downloadTooLarge(limitBytes: 50 * 1024 * 1024),
            HeadlessInstallError.invalidWidgetID("Bad ID"),
            HeadlessInstallError.needsNewerHost("Needs BarShelf 9.0 or later"),
            WidgetDiscovery.DiscoveryError.subdirectoryNotFound("widgets/clock"),
            CocoaError(.fileWriteNoPermission),
        ]
        for error in errors {
            let failure = WidgetInstallFlow.explainFailure(error)
            XCTAssertFalse(failure.cause.isEmpty, "\(error)")
            XCTAssertFalse(failure.fix.isEmpty, "\(error)")
            XCTAssertEqual(WidgetInstallFlow.userFacingDescription(of: error), failure.message)
        }
    }

    func testSkippedFolderLinesAreReadable() {
        let line = WidgetInstallFlow.describeSkipped(.init(relativePath: "clock", reason: "invalid widget.json: typeMismatch(Swift.Int…)"))
        XCTAssertTrue(line.hasPrefix("clock: "))
        XCTAssertFalse(line.contains("typeMismatch"))
    }
}
