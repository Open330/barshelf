import Foundation
import XCTest

@testable import MenubucketCore

/// First-run starter seeding (R07 onboarding): fresh installs get the
/// CLI-free starter widgets copied from the app bundle exactly once.
final class StarterWidgetSeederTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private var bundledDir: URL { root.appendingPathComponent("bundle-widgets", isDirectory: true) }
    private var appSupportDir: URL { root.appendingPathComponent("app-support", isDirectory: true) }
    private var userWidgetsDir: URL { appSupportDir.appendingPathComponent("widgets", isDirectory: true) }
    private var markerURL: URL {
        appSupportDir.appendingPathComponent(StarterWidgetSeeder.markerFileName)
    }

    /// Bundled resources: the two starters plus a CLI-dependent widget that
    /// must never be seeded.
    private func makeBundledWidgets(
        names: [String] = ["hello", "recent-files", "aas-usage"]
    ) throws {
        let fm = FileManager.default
        for name in names {
            let dir = bundledDir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{\"id\": \"dev.menubucket.\(name)\"}".utf8)
                .write(to: dir.appendingPathComponent("widget.json"))
            try Data("#!/bin/sh\n".utf8)
                .write(to: dir.appendingPathComponent("main.sh"))
        }
    }

    private func seed(devDirectory: URL? = nil) -> StarterWidgetSeeder.Outcome {
        StarterWidgetSeeder.seedIfNeeded(
            bundledWidgetsDirectory: bundledDir,
            userWidgetsDirectory: userWidgetsDir,
            developmentWidgetsDirectory: devDirectory
        )
    }

    // MARK: Tests

    func testSeedsStartersIntoEmptyUserDirectory() throws {
        try makeBundledWidgets()

        let outcome = seed()

        XCTAssertEqual(outcome.seededNames, ["hello", "recent-files"])
        XCTAssertTrue(outcome.didSeed)
        let fm = FileManager.default
        for name in StarterWidgetSeeder.starterWidgetNames {
            let manifest = userWidgetsDir
                .appendingPathComponent(name)
                .appendingPathComponent("widget.json")
            XCTAssertTrue(fm.fileExists(atPath: manifest.path), name)
        }
        // Non-starter bundled widgets (CLI/deno dependent) are not copied.
        XCTAssertFalse(fm.fileExists(
            atPath: userWidgetsDir.appendingPathComponent("aas-usage").path
        ))
        // Marker written so the next launch skips seeding.
        XCTAssertTrue(fm.fileExists(atPath: markerURL.path))
    }

    func testMarkerPreventsReseeding() throws {
        try makeBundledWidgets()
        XCTAssertTrue(seed().didSeed)

        // User deletes the starters on purpose — they must stay gone.
        try FileManager.default.removeItem(at: userWidgetsDir)
        let second = seed()

        XCTAssertFalse(second.didSeed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userWidgetsDir.path))
    }

    func testDevelopmentDirectoryDisablesSeeding() throws {
        try makeBundledWidgets()
        let devDir = root.appendingPathComponent("dev-widgets", isDirectory: true)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)

        let outcome = seed(devDirectory: devDir)

        XCTAssertFalse(outcome.didSeed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userWidgetsDir.path))
        // No marker either: dev mode must stay fully unchanged.
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testMissingDevelopmentDirectoryStillSeeds() throws {
        try makeBundledWidgets()
        let devDir = root.appendingPathComponent("does-not-exist", isDirectory: true)

        XCTAssertTrue(seed(devDirectory: devDir).didSeed)
    }

    func testExistingUserWidgetsAreNeverTouched() throws {
        try makeBundledWidgets()
        let fm = FileManager.default
        let existing = userWidgetsDir.appendingPathComponent("my-widget", isDirectory: true)
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("{\"id\": \"my.widget\"}".utf8)
            .write(to: existing.appendingPathComponent("widget.json"))

        let outcome = seed()

        XCTAssertFalse(outcome.didSeed)
        XCTAssertFalse(fm.fileExists(atPath: userWidgetsDir.appendingPathComponent("hello").path))
        // Marker written anyway: an existing user is "already onboarded".
        XCTAssertTrue(fm.fileExists(atPath: markerURL.path))
        // Calling again stays a no-op.
        XCTAssertFalse(seed().didSeed)
    }

    func testMissingBundledDirectoryIsANoOpWithoutMarker() throws {
        // No bundled resources (plain `swift build` binary, cwd without
        // ./widgets/): nothing seeded, and no marker so a later packaged
        // launch can still seed.
        let outcome = seed()

        XCTAssertFalse(outcome.didSeed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testNilBundledDirectoryIsANoOp() {
        let outcome = StarterWidgetSeeder.seedIfNeeded(
            bundledWidgetsDirectory: nil,
            userWidgetsDirectory: userWidgetsDir,
            developmentWidgetsDirectory: nil
        )
        XCTAssertFalse(outcome.didSeed)
    }

    func testSeededWidgetContentsAreCopied() throws {
        try makeBundledWidgets()
        _ = seed()

        let script = userWidgetsDir
            .appendingPathComponent("hello")
            .appendingPathComponent("main.sh")
        XCTAssertEqual(
            try String(contentsOf: script, encoding: .utf8), "#!/bin/sh\n"
        )
    }
}
