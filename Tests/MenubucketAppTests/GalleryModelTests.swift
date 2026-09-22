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
        try Data("{ \"version\": \"1.0\" }".utf8)
            .write(to: initialDirectory.appendingPathComponent("widget.json"))
        model.setEntries(forPreview: [alreadyInstalled, entry])
        model.onWindowShown()
        try await waitUntil {
            model.installedIDs == [alreadyInstalled.id]
                && model.installedVersions[alreadyInstalled.id] == "1.0"
        }

        let directory = widgets.appendingPathComponent(entry.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ \"version\": \"1.0\" }".utf8)
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
        try Data("{ \"version\": \"1.0\" }".utf8)
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
