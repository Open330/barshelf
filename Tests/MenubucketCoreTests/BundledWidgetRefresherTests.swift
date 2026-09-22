import Foundation
import XCTest

@testable import MenubucketCore

/// Bundled widget refresh: a widget's behaviour is data, so an app release
/// that changes `workflow.json` has to reach machines that already have the
/// widget — without resurrecting deleted ones or clobbering local edits.
final class BundledWidgetRefresherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private var bundledDir: URL { root.appendingPathComponent("bundle-widgets", isDirectory: true) }
    private var appSupportDir: URL { root.appendingPathComponent("app-support", isDirectory: true) }
    private var userWidgetsDir: URL { appSupportDir.appendingPathComponent("widgets", isDirectory: true) }
    private var ledgerURL: URL {
        appSupportDir.appendingPathComponent(BundledWidgetRefresher.ledgerFileName)
    }

    @discardableResult
    private func writeWidget(
        into parent: URL,
        directoryName: String,
        id: String,
        version: String?,
        body: String = "v1"
    ) throws -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent(directoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest = "{\"id\": \"\(id)\""
        if let version { manifest += ", \"version\": \"\(version)\"" }
        manifest += "}"
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("widget.json"))
        try Data(body.utf8).write(to: dir.appendingPathComponent("workflow.json"))
        return dir
    }

    private func refresh(devDirectory: URL? = nil) -> BundledWidgetRefresher.Outcome {
        BundledWidgetRefresher.refreshIfNeeded(
            bundledWidgetsDirectory: bundledDir,
            userWidgetsDirectory: userWidgetsDir,
            developmentWidgetsDirectory: devDirectory
        )
    }

    private func body(ofInstalled directoryName: String) throws -> String {
        try String(
            contentsOf: userWidgetsDir
                .appendingPathComponent(directoryName)
                .appendingPathComponent("workflow.json"),
            encoding: .utf8
        )
    }

    private func installedVersion(_ directoryName: String) -> String? {
        ManifestSummary.read(
            fromWidgetDirectory: userWidgetsDir.appendingPathComponent(directoryName)
        )?.version
    }

    // MARK: Tests

    func testRefreshesInstalledWidgetWhenBundleIsNewer() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "no decimals"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "decimals"
        )

        let outcome = refresh()

        XCTAssertTrue(outcome.didRefresh)
        XCTAssertEqual(outcome.refreshed.map(\.id), ["dev.barshelf.system"])
        XCTAssertEqual(outcome.refreshed.first?.from, "0.3.0")
        XCTAssertEqual(outcome.refreshed.first?.to, "0.3.1")
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "no decimals")
        XCTAssertEqual(installedVersion("dev.barshelf.system"), "0.3.1")
    }

    func testNeverInstallsAWidgetTheUserDoesNotHave() throws {
        try writeWidget(
            into: bundledDir, directoryName: "sensors",
            id: "dev.barshelf.sensors", version: "0.2.1"
        )
        // The user has a different widget installed — sensors was deleted on
        // purpose (or never installed) and must stay gone.
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0"
        )

        let outcome = refresh()

        XCTAssertFalse(outcome.didRefresh)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: userWidgetsDir.appendingPathComponent("dev.barshelf.sensors").path
        ))
    }

    func testEqualAndOlderBundledVersionsLeaveTheInstallAlone() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.0", body: "bundled"
        )
        try writeWidget(
            into: bundledDir, directoryName: "sensors",
            id: "dev.barshelf.sensors", version: "0.1.0", body: "bundled"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "installed"
        )
        // A newer install than the bundle (user updated from the gallery)
        // must never be rolled back.
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.sensors",
            id: "dev.barshelf.sensors", version: "0.2.1", body: "installed"
        )

        let outcome = refresh()

        XCTAssertFalse(outcome.didRefresh)
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "installed")
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.sensors"), "installed")
        XCTAssertEqual(installedVersion("dev.barshelf.sensors"), "0.2.1")
    }

    func testMatchesByManifestIDNotDirectoryName() throws {
        // Seeding copies starters under their folder name; installs use the
        // manifest id. The refresher has to update whichever is on disk.
        try writeWidget(
            into: bundledDir, directoryName: "today",
            id: "dev.barshelf.today", version: "1.1.0", body: "new"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "today",
            id: "dev.barshelf.today", version: "1.0.0", body: "old"
        )

        let outcome = refresh()

        XCTAssertEqual(outcome.refreshed.map(\.directoryName), ["today"])
        XCTAssertEqual(try body(ofInstalled: "today"), "new")
        // No second copy appeared under the manifest id.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: userWidgetsDir.appendingPathComponent("dev.barshelf.today").path
        ))
    }

    func testInstanceSymlinksAreSkippedAndKeepResolving() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "new"
        )
        let real = try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "old"
        )
        // Duplicated widget instances are symlinks next to the real directory.
        let alias = userWidgetsDir.appendingPathComponent("dev.barshelf.system--ram")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let outcome = refresh()

        // Refreshed once, via the real directory.
        XCTAssertEqual(outcome.refreshed.map(\.directoryName), ["dev.barshelf.system"])
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "new")
        // The alias is still a symlink and now resolves to the fresh copy.
        let values = try alias.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(
            try String(
                contentsOf: alias.appendingPathComponent("workflow.json"), encoding: .utf8
            ),
            "new"
        )
    }

    func testLocallyModifiedWidgetIsNotOverwritten() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.0", body: "bundled"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "bundled"
        )
        // First launch records what is on disk (versions already match).
        XCTAssertFalse(refresh().didRefresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))

        // The user edits the workflow, then a newer version ships.
        try Data("hand edited".utf8).write(
            to: userWidgetsDir
                .appendingPathComponent("dev.barshelf.system")
                .appendingPathComponent("workflow.json")
        )
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.4.0", body: "bundled v2"
        )

        let outcome = refresh()

        XCTAssertFalse(outcome.didRefresh)
        XCTAssertEqual(outcome.skippedLocallyModified, ["dev.barshelf.system"])
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "hand edited")
    }

    func testUntouchedWidgetIsRefreshedOnTheSecondLaunch() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.0", body: "bundled"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "bundled"
        )
        XCTAssertFalse(refresh().didRefresh)

        // No local edits — the ledger digest still matches, so the next
        // release lands.
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.4.0", body: "bundled v2"
        )

        let outcome = refresh()

        XCTAssertEqual(outcome.refreshed.map(\.id), ["dev.barshelf.system"])
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "bundled v2")
        XCTAssertTrue(outcome.skippedLocallyModified.isEmpty)
    }

    func testRefreshIsIdempotent() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "new"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "old"
        )

        XCTAssertTrue(refresh().didRefresh)
        XCTAssertFalse(refresh().didRefresh)
        XCTAssertFalse(refresh().didRefresh)
    }

    func testDevelopmentDirectoryDisablesRefreshing() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "new"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "old"
        )
        let devDir = root.appendingPathComponent("dev-widgets", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)

        let outcome = refresh(devDirectory: devDir)

        XCTAssertFalse(outcome.didRefresh)
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.path))
    }

    func testMissingBundleOrEmptyInstallIsANoOp() throws {
        // No bundled resources at all (plain `swift build` binary).
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0"
        )
        XCTAssertFalse(refresh().didRefresh)

        // Bundle present, nothing installed.
        try FileManager.default.removeItem(at: userWidgetsDir)
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1"
        )
        XCTAssertFalse(refresh().didRefresh)

        XCTAssertFalse(
            BundledWidgetRefresher.refreshIfNeeded(
                bundledWidgetsDirectory: nil, userWidgetsDirectory: userWidgetsDir
            ).didRefresh
        )
    }

    func testVersionlessInstallIsAdoptedByAVersionedBundle() throws {
        // Hand-written widgets may omit `version`; anything the bundle
        // declares counts as newer.
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "new"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: nil, body: "old"
        )

        let outcome = refresh()

        XCTAssertEqual(outcome.refreshed.first?.from, nil)
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "new")
    }

    func testUnreadableManifestIsSkippedWithoutBlockingOthers() throws {
        try writeWidget(
            into: bundledDir, directoryName: "system",
            id: "dev.barshelf.system", version: "0.3.1", body: "new"
        )
        try writeWidget(
            into: userWidgetsDir, directoryName: "dev.barshelf.system",
            id: "dev.barshelf.system", version: "0.3.0", body: "old"
        )
        // A broken widget directory sorted before the good one.
        let broken = userWidgetsDir.appendingPathComponent("aaa-broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("widget.json"))

        let outcome = refresh()

        XCTAssertEqual(outcome.refreshed.map(\.id), ["dev.barshelf.system"])
        XCTAssertEqual(try body(ofInstalled: "dev.barshelf.system"), "new")
    }

    func testDigestNoticesContentAndLayoutChanges() throws {
        let dir = try writeWidget(
            into: root, directoryName: "digest-a",
            id: "dev.barshelf.x", version: "1.0.0", body: "same"
        )
        let baseline = BundledWidgetRefresher.digest(of: dir)
        XCTAssertFalse(baseline.isEmpty)
        XCTAssertEqual(baseline, BundledWidgetRefresher.digest(of: dir))

        try Data("changed".utf8).write(to: dir.appendingPathComponent("workflow.json"))
        XCTAssertNotEqual(baseline, BundledWidgetRefresher.digest(of: dir))

        // A new file with no content change still moves the digest.
        try Data("same".utf8).write(to: dir.appendingPathComponent("workflow.json"))
        XCTAssertEqual(baseline, BundledWidgetRefresher.digest(of: dir))
        try Data("".utf8).write(to: dir.appendingPathComponent("extra.json"))
        XCTAssertNotEqual(baseline, BundledWidgetRefresher.digest(of: dir))
    }
}
