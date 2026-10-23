import Combine
import XCTest
@testable import MenubucketApp
import MenubucketCore

@MainActor
final class GalleryModelTests: XCTestCase {
    func testExternalInstallIsObservedWhileGalleryIsVisible() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-\(UUID().uuidString)")
        let widgets = root.appendingPathComponent("widgets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = GalleryModel(widgetsDirectory: widgets)
        let alreadyInstalled = makeEntry(id: "dev.test.initial", version: "1.0")
        let entry = makeEntry(id: "dev.test.external-install", version: "2.0")
        let initialDirectory = widgets.appendingPathComponent(
            alreadyInstalled.id, isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: initialDirectory, withIntermediateDirectories: true
        )
        try Self.manifest(id: alreadyInstalled.id, version: "1.0")
            .write(to: initialDirectory.appendingPathComponent("widget.json"))
        model.setEntries(forPreview: [alreadyInstalled, entry])
        model.onWindowShown()
        try await waitUntil {
            model.installedIDs == [alreadyInstalled.id]
                && model.installedVersions[alreadyInstalled.id] == "1.0"
        }

        let directory = widgets.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.manifest(id: entry.id, version: "1.0")
            .write(to: directory.appendingPathComponent("widget.json"))

        try await waitUntil(timeout: 3) {
            model.installedIDs == [alreadyInstalled.id, entry.id]
                && model.installedVersions[entry.id] == "1.0"
        }
    }

    func testInstalledStateOnlyPublishesChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-\(UUID().uuidString)")
        let widgets = root.appendingPathComponent("widgets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = makeEntry(id: "dev.test.version", version: "2.0")
        let directory = widgets.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.manifest(id: entry.id, version: "1.0")
            .write(to: directory.appendingPathComponent("widget.json"))

        let model = GalleryModel(widgetsDirectory: widgets)
        model.setEntries(forPreview: [entry])
        model.onWindowShown()
        try await waitUntil { model.installedVersions[entry.id] == "1.0" }

        let expectation = expectation(description: "no duplicate installed-state publication")
        expectation.isInverted = true
        let observation = model.objectWillChange.sink { expectation.fulfill() }
        model.refreshInstalledStates()
        await fulfillment(of: [expectation], timeout: 0.25)
        withExtendedLifetime(observation) {}
    }

    func testGalleryRechecksInjectedRequirementAfterToolIsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-requirements-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checker = RequirementChecker(searchDirectories: { [root.path] })
        let model = GalleryModel(
            widgetsDirectory: root.appendingPathComponent("widgets"),
            requirementChecker: checker
        )
        var entry = makeEntry(id: "dev.test.requirements", version: "1.0")
        entry.requires = "gallery-fixture CLI"
        model.setEntries(forPreview: [entry])
        model.onWindowShown()

        try await waitUntil {
            model.requirementStatus[entry.id] == .missing
        }

        let executable = root.appendingPathComponent("gallery-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        // Re-entering the gallery is the explicit recheck path used after a
        // user installs a CLI without restarting BarShelf.
        model.onWindowShown()
        try await waitUntil {
            model.requirementStatus[entry.id] == .satisfied
        }
    }

    func testForcedRefreshShowsCachedRegistryNoticeAndClearFiltersResetsAll() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = URL(string: "https://gallery-fixture.invalid/index.json")!
        let client = RegistryClient(configuration: .init(
            defaultRemoteURL: remote,
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            fetch: { _ in throw RegistryError.fileNotFound("offline") }
        ))
        let cache = client.cacheFileURL(for: remote)
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        { "schemaVersion": 1, "widgets": [{
          "id": "dev.test.cached", "name": "Cached widget", "kind": "exec",
          "tags": ["fixture"], "install": { "url": "https://example.invalid/widget" }
        }] }
        """.utf8).write(to: cache)

        let model = GalleryModel(
            client: client,
            widgetsDirectory: root.appendingPathComponent("widgets")
        )
        model.onWindowShown()
        try await waitUntil { model.entries.count == 1 }
        model.searchText = "no match"
        model.kindFilter = .script
        model.selectedCategory = "fixture"
        model.clearFilters()
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.kindFilter, .all)
        XCTAssertNil(model.selectedCategory)

        model.refresh(force: true)
        try await waitUntil {
            model.registryNotice == "Couldn’t refresh the registry. Showing cached widgets."
                && model.entries.map(\.id) == ["dev.test.cached"]
        }
    }

    func testHidingGalleryCancelsPendingLoadAndDropsItsLateResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-hidden-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fetch = SuspendedFetch()
        let remote = URL(string: "https://gallery-fixture.invalid/index.json")!
        let client = RegistryClient(configuration: .init(
            environment: [:],
            defaultRemoteURL: remote,
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            fetch: { _ in try await fetch.data() }
        ))
        let model = GalleryModel(
            client: client,
            widgetsDirectory: root.appendingPathComponent("widgets", isDirectory: true)
        )

        model.onWindowShown()
        await fetch.waitUntilRequested()
        XCTAssertTrue(model.isLoading)

        model.onWindowHidden()
        XCTAssertFalse(model.isLoading)
        await fetch.succeed(with: Self.registryData(id: "dev.test.late"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.loadError)
    }

    /// Issue #1: nothing watches the disk while the hub window is hidden or
    /// covered, and coming back rescans once.
    func testHiddenWindowStopsWatchingAndRescansWhenShownAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-occluded-\(UUID().uuidString)")
        let widgets = root.appendingPathComponent("widgets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)

        let model = GalleryModel(widgetsDirectory: widgets)
        let entry = makeEntry(id: "dev.test.while-hidden", version: "1.0")
        model.setEntries(forPreview: [entry])
        model.onWindowShown()
        XCTAssertTrue(model.isWatchingInstalledWidgets)

        model.setWindowVisible(false)
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isWatchingInstalledWidgets)

        let directory = widgets.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.manifest(id: entry.id, version: "1.0")
            .write(to: directory.appendingPathComponent("widget.json"))
        model.refreshInstalledStates()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.installedIDs.isEmpty, "no scan while the window is hidden")

        model.setWindowVisible(true)
        XCTAssertTrue(model.isWatchingInstalledWidgets)
        try await waitUntil { model.installedIDs == [entry.id] }

        model.onWindowHidden()
        XCTAssertFalse(model.isWatchingInstalledWidgets)
    }

    func testSearchMatchesDescriptionAndTypeAndCategoriesAreCurated() {
        let model = GalleryModel(
            widgetsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("barshelf-gallery-search-\(UUID().uuidString)")
        )
        var weather = makeEntry(id: "dev.test.weather", version: "1.0")
        weather.description = "Forecast for your city"
        weather.kind = "workflow"
        weather.category = "Demo"
        weather.tags = ["http", "native"]
        var otp = makeEntry(id: "dev.test.otp", version: "1.0")
        otp.kind = "exec"
        otp.category = "Security"
        otp.tags = ["2fa"]
        model.setEntries(forPreview: [weather, otp])

        XCTAssertEqual(model.availableCategories, ["Demo", "Security"])
        model.searchText = "forecast"
        XCTAssertEqual(model.filteredEntries.map(\.id), [weather.id])
        model.searchText = "command"
        XCTAssertEqual(model.filteredEntries.map(\.id), [otp.id])
        model.searchText = "2FA"
        XCTAssertEqual(model.filteredEntries.map(\.id), [otp.id])

        model.searchText = ""
        model.selectedCategory = "Security"
        XCTAssertTrue(model.pickerFiltersAreActive)
        XCTAssertFalse(model.isSearching)
        model.clearPickerFilters()
        XCTAssertFalse(model.filtersAreActive)
    }

    func testSectionCopyNamesNoPersonalTools() {
        let model = GalleryModel(
            widgetsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("barshelf-gallery-sections-\(UUID().uuidString)")
        )
        var custom = makeEntry(id: "dev.test.custom", version: "1.0")
        custom.collection = "custom"
        model.setEntries(forPreview: [makeEntry(id: "dev.test.builtin", version: "1.0"), custom])
        let copy = model.sections.map { "\($0.title) \($0.subtitle)" }.joined(separator: " ")
        XCTAssertEqual(model.sections.count, 2)
        for name in ["muxa", "aas", "otpeek", "stashbar", "built-in", "custom"] {
            XCTAssertFalse(copy.lowercased().contains(name), name)
        }
    }

    func testDetailOpensAndClosesForAnEntry() {
        let model = GalleryModel(
            widgetsDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("barshelf-gallery-detail-\(UUID().uuidString)")
        )
        let entry = makeEntry(id: "dev.test.detail", version: "1.0")
        model.setEntries(forPreview: [entry])
        model.showDetail(entry)
        XCTAssertEqual(model.detailEntry?.id, entry.id)
        model.closeDetail()
        XCTAssertNil(model.detailEntry)
    }

    /// A valid `widget.json`: installed state is read from the manifest's id.
    private static func manifest(id: String, version: String) -> Data {
        Data("""
        { "schemaVersion": 1, "id": "\(id)", "name": "\(id)", "version": "\(version)",
          "entry": { "kind": "workflow" } }
        """.utf8)
    }

    /// Starters seeded on first run sit in folders named after the bundled
    /// folder (`today`), not the manifest id — the Hub showed them installed
    /// while the Gallery offered to install them again.
    func testSeededFoldersCountAsInstalledByTheirManifestID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-gallery-seeded-\(UUID().uuidString)")
        let widgets = root.appendingPathComponent("widgets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = [
            ("today", "dev.barshelf.today"),
            ("recent-files-grid", "dev.barshelf.recent-files-grid"),
            ("quick-shelf", "dev.barshelf.quick-shelf"),
        ]
        for (folder, id) in seeded {
            let directory = widgets.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.manifest(id: id, version: "0.1.0").write(to: directory.appendingPathComponent("widget.json"))
        }
        // A folder named after a registry id whose manifest is something else,
        // and one whose manifest does not decode, install nothing.
        let mismatched = widgets.appendingPathComponent("dev.barshelf.clock", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatched, withIntermediateDirectories: true)
        try Self.manifest(id: "dev.someone.else", version: "1").write(to: mismatched.appendingPathComponent("widget.json"))
        let broken = widgets.appendingPathComponent("dev.barshelf.weather", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ \"version\": \"1.0\" }".utf8).write(to: broken.appendingPathComponent("widget.json"))

        // A package that is a link to a project folder is installed too:
        // BarShelf runs it (the installer only refuses to update through it).
        let project = root.appendingPathComponent("projects/stock", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.manifest(id: "dev.barshelf.stock", version: "2").write(to: project.appendingPathComponent("widget.json"))
        try FileManager.default.createSymbolicLink(at: widgets.appendingPathComponent("stock"), withDestinationURL: project)

        let entries = seeded.map { makeEntry(id: $0.1, version: "0.1.1") }
            + [makeEntry(id: "dev.barshelf.clock", version: "1"), makeEntry(id: "dev.barshelf.weather", version: "1"),
               makeEntry(id: "dev.barshelf.stock", version: "2")]
        let model = GalleryModel(widgetsDirectory: widgets)
        model.setEntries(forPreview: entries)
        model.onWindowShown()
        try await waitUntil { model.installedIDs.count == 4 }
        XCTAssertEqual(model.installedIDs, Set(seeded.map(\.1) + ["dev.barshelf.stock"]))
        XCTAssertEqual(model.installedVersions["dev.barshelf.stock"], "2")
        for (_, id) in seeded {
            XCTAssertEqual(model.installedVersions[id], "0.1.0")
            let entry = try XCTUnwrap(entries.first { $0.id == id })
            XCTAssertTrue(model.updateAvailable(for: entry), "an older seeded copy offers Update, not Install")
        }
    }

    private func makeEntry(id: String, version: String) -> RegistryWidgetEntry {
        RegistryWidgetEntry(
            id: id,
            name: id,
            version: version,
            install: .init(url: "https://example.invalid/\(id)")
        )
    }

    private static func registryData(id: String) -> Data {
        Data("""
        { "schemaVersion": 1, "widgets": [{
          "id": "\(id)", "name": "Late widget", "kind": "exec",
          "install": { "url": "https://example.invalid/widget" }
        }] }
        """.utf8)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Gallery installed-state refresh did not finish in time")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private actor SuspendedFetch {
    private var continuation: CheckedContinuation<Data, Error>?
    private var requested = false

    func data() async throws -> Data {
        requested = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while !requested {
            await Task.yield()
        }
    }

    func succeed(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
