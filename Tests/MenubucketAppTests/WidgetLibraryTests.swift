import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: holds the loaded widgets and records, in
/// order, everything the library asks of it.
@MainActor
private final class StubHost: WidgetLibraryHost {
    var widgets: [LoadedWidget] = []
    private(set) var events: [String] = []
    /// Runs while the library waits for the widget's work to stop.
    var whileStopping: (String) async -> Void = { _ in }

    func stopWidgetAndWaitForItsWork(_ widgetID: String) async {
        events.append("stop:\(widgetID)")
        await whileStopping(widgetID)
    }

    func forgetWorkflowAlerts(widgetID: String) { events.append("forgetAlerts:\(widgetID)") }
    func resumeWidget(_ widgetID: String) { events.append("resume:\(widgetID)") }
    func forgetCachedSnapshot(widgetID: String) { events.append("forgetSnapshot:\(widgetID)") }
    func reloadWidgets() { events.append("reload") }
}

private final class FailingSecretStore: SecretStoring, @unchecked Sendable {
    let base = InMemorySecretStore()
    func get(widgetId: String, key: String) throws -> String? { try base.get(widgetId: widgetId, key: key) }
    func set(widgetId: String, key: String, value: String) throws {
        try base.set(widgetId: widgetId, key: key, value: value)
    }
    func removeAll(widgetId: String) throws { throw CocoaError(.fileWriteUnknown) }
}

final class WidgetLibraryDecisionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/nonexistent/library/widgets", isDirectory: true)

    func testOnlyAProperSubdirectoryOfTheRootIsRemovable() {
        XCTAssertTrue(WidgetLibrary.isRemovable(root.appendingPathComponent("a"), under: root))
        XCTAssertFalse(WidgetLibrary.isRemovable(root, under: root))
        XCTAssertFalse(WidgetLibrary.isRemovable(root.appendingPathComponent("../../etc"), under: root))
        XCTAssertFalse(WidgetLibrary.isRemovable(root.appendingPathComponent("a/../.."), under: root))
        XCTAssertFalse(WidgetLibrary.isRemovable(
            URL(fileURLWithPath: "/nonexistent/library/widgets-other/a"), under: root
        ))
    }

    func testAnInstanceLabelIsLowercasedAndItsSeparatorsCollapsed() {
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("  Work Mail  "), "work-mail")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("a // b"), "a-b")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("v1.2_beta-3"), "v1.2_beta-3")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("-.work._"), "work")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("../../etc"), "etc")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("업무"), "업무")
    }

    func testALabelWithNoLetterOrDigitNormalizesToNothing() {
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel(""), "")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel(" /!? "), "")
        XCTAssertEqual(WidgetLibrary.normalizedInstanceLabel("-._"), "")
    }

    func testTheRuntimeEntryPointsAnswerTheSame() {
        let inside = WidgetRuntime.userWidgetsRoot.appendingPathComponent("a")
        XCTAssertEqual(
            WidgetRuntime.isRemovableWidgetDirectory(inside),
            WidgetLibrary.isRemovable(inside, under: WidgetRuntime.userWidgetsRoot)
        )
        XCTAssertEqual(WidgetRuntime.normalizedInstanceLabel("Work Mail"), "work-mail")
    }
}

@MainActor
final class WidgetLibraryTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL!
    private var host: StubHost!
    private var secrets: InMemorySecretStore!
    private var storage: StorageService!
    private var prefs: WidgetPrefs!
    private var permissions: PermissionStore!
    private var library: WidgetLibrary!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-library-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("widgets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = StubHost()
        secrets = InMemorySecretStore()
        storage = StorageService(directory: sandbox.appendingPathComponent("storage", isDirectory: true))
        prefs = WidgetPrefs(fileURL: sandbox.appendingPathComponent("widget-prefs.json"))
        permissions = PermissionStore(fileURL: sandbox.appendingPathComponent("permissions.json"))
        library = makeLibrary(secrets: secrets)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeLibrary(secrets: SecretStoring) -> WidgetLibrary {
        let library = WidgetLibrary(
            root: root, secretStore: secrets, storage: storage, prefs: prefs, permissionStore: permissions
        )
        library.host = host
        return library
    }

    private func manifest(_ id: String, name: String = "Sample") -> Manifest {
        Manifest(schemaVersion: 1, id: id, name: name,
                 entry: .init(kind: "exec"),
                 source: .init(command: ["/usr/bin/true"]),
                 permissions: .init(exec: [.init(command: "/usr/bin/true")]))
    }

    /// Writes a package folder under `directory` and loads it into the host.
    @discardableResult
    private func install(_ id: String, in directory: URL? = nil, folder: String? = nil) throws -> LoadedWidget {
        let manifest = manifest(id)
        let folderURL = (directory ?? root).appendingPathComponent(folder ?? id, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folderURL.appendingPathComponent("widget.json"))
        let widget = LoadedWidget(manifest: manifest, directory: folderURL)
        host.widgets.append(widget)
        return widget
    }

    /// What a rescan would find after `duplicate`: the instance behind its link.
    private func loadInstance(_ instanceID: String, of widget: LoadedWidget) -> LoadedWidget {
        let instance = LoadedWidget(
            manifest: widget.manifest,
            directory: root.appendingPathComponent(instanceID, isDirectory: true),
            instanceID: instanceID
        )
        host.widgets.append(instance)
        return instance
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func assertThrows(
        _ expected: (WidgetRuntime.RuntimeError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch let error as WidgetRuntime.RuntimeError {
            XCTAssertTrue(expected(error), "unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func isNotFound(_ error: WidgetRuntime.RuntimeError) -> Bool {
        if case .widgetNotFound = error { return true }
        return false
    }

    private func isNotRemovable(_ error: WidgetRuntime.RuntimeError) -> Bool {
        if case .notRemovable = error { return true }
        return false
    }

    private func isInvalidName(_ error: WidgetRuntime.RuntimeError) -> Bool {
        if case .invalidInstanceName = error { return true }
        return false
    }

    // MARK: - Remove

    func testRemovingStopsPurgesDeletesAndRescansInThatOrder() async throws {
        let widget = try install("dev.test.remove")
        try secrets.set(widgetId: widget.id, key: "token", value: "secret")
        try storage.set(widgetId: widget.id, key: "notes", value: .string("saved"))
        prefs.setSetting(widgetID: widget.id, key: "city", value: .string("Seoul"))
        prefs.togglePin(widget.id)
        permissions.approve(widget.manifest)
        var directoryExistedWhileStopping = false
        host.whileStopping = { [unowned self] _ in
            directoryExistedWhileStopping = self.exists(widget.directory)
                && self.storage.get(widgetId: widget.id, key: "notes") != nil
        }

        try await library.remove(id: widget.id)

        XCTAssertEqual(host.events, [
            "stop:dev.test.remove", "forgetAlerts:dev.test.remove",
            "forgetSnapshot:dev.test.remove", "reload",
        ])
        XCTAssertTrue(directoryExistedWhileStopping, "nothing may be erased before the widget's work has stopped")
        XCTAssertFalse(exists(widget.directory))
        XCTAssertNil(try secrets.get(widgetId: widget.id, key: "token"))
        XCTAssertNil(storage.get(widgetId: widget.id, key: "notes"))
        XCTAssertTrue(prefs.settings(for: widget.id).isEmpty)
        XCTAssertFalse(prefs.isPinned(widget.id))
        XCTAssertEqual(permissions.status(for: widget.manifest), .pending)
        XCTAssertFalse(library.isRemoving(widget.id))
    }

    func testRemovingACopyKeepsThePackagesDecisionAndTheOriginalsData() async throws {
        let widget = try install("dev.test.copies")
        let copyID = try library.duplicate(id: widget.id, label: "work")
        let copy = loadInstance(copyID, of: widget)
        permissions.approve(widget.manifest)
        for id in [widget.id, copy.id] {
            try secrets.set(widgetId: id, key: "token", value: id)
            try storage.set(widgetId: id, key: "notes", value: .string(id))
        }

        try await library.remove(id: copy.id)

        XCTAssertFalse(exists(copy.directory), "the link goes")
        XCTAssertTrue(exists(widget.directory.appendingPathComponent("widget.json")), "the package it pointed at stays")
        XCTAssertNil(try secrets.get(widgetId: copy.id, key: "token"))
        XCTAssertNil(storage.get(widgetId: copy.id, key: "notes"))
        XCTAssertEqual(try secrets.get(widgetId: widget.id, key: "token"), widget.id)
        XCTAssertEqual(storage.get(widgetId: widget.id, key: "notes"), .string(widget.id))
        XCTAssertEqual(permissions.status(for: widget.manifest), .approved)
    }

    func testAnUnknownWidgetIsNotFoundAndNothingIsAsked() async {
        await assertThrows(isNotFound) { try await self.library.remove(id: "dev.test.missing") }
        XCTAssertEqual(host.events, [])
    }

    func testWithoutAHostNoWidgetIsKnown() async throws {
        let widget = try install("dev.test.no-host")
        library.host = nil
        await assertThrows(isNotFound) { try await self.library.remove(id: widget.id) }
        XCTAssertThrowsError(try library.duplicate(id: widget.id, label: "work"))
        XCTAssertTrue(exists(widget.directory))
    }

    func testAWidgetOutsideTheRootIsNeverDeleted() async throws {
        let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        let widget = try install("dev.test.outside", in: elsewhere)
        await assertThrows(isNotRemovable) { try await self.library.remove(id: widget.id) }
        XCTAssertTrue(exists(widget.directory))
        XCTAssertEqual(host.events, [])
        XCTAssertFalse(library.isRemoving(widget.id))
    }

    func testTheOriginalIsRefusedWhileACopyOfItIsOnDisk() async throws {
        let widget = try install("dev.test.original")
        try library.duplicate(id: widget.id, label: "work")
        await assertThrows(isNotRemovable) { try await self.library.remove(id: widget.id) }
        XCTAssertTrue(exists(widget.directory))
        XCTAssertEqual(host.events, ["reload"], "only the duplicate's rescan")
    }

    func testAFailedPurgeLeavesTheWidgetInstalledAndResumesIt() async throws {
        let failing = FailingSecretStore()
        library = makeLibrary(secrets: failing)
        let widget = try install("dev.test.purge-fails")
        try storage.set(widgetId: widget.id, key: "notes", value: .string("keep me"))
        prefs.setSetting(widgetID: widget.id, key: "city", value: .string("Seoul"))
        permissions.approve(widget.manifest)

        do {
            try await library.remove(id: widget.id)
            XCTFail("removal reported success although the secrets were not erased")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }

        XCTAssertEqual(host.events, ["stop:dev.test.purge-fails", "resume:dev.test.purge-fails"])
        XCTAssertTrue(exists(widget.directory))
        XCTAssertEqual(storage.get(widgetId: widget.id, key: "notes"), .string("keep me"))
        XCTAssertEqual(prefs.settings(for: widget.id)["city"], .string("Seoul"))
        XCTAssertEqual(permissions.status(for: widget.manifest), .approved)
        XCTAssertFalse(library.isRemoving(widget.id), "a failed removal lets the widget run again")
    }

    func testAWidgetIsBeingRemovedOnlyWhileItsRemovalRuns() async throws {
        let widget = try install("dev.test.removing")
        XCTAssertFalse(library.isRemoving(widget.id))
        var wasRemoving = false
        var duplicateWasRefused = false
        host.whileStopping = { [unowned self] id in
            wasRemoving = self.library.isRemoving(id)
            do {
                try self.library.duplicate(id: id, label: "late")
            } catch {
                duplicateWasRefused = true
            }
        }

        try await library.remove(id: widget.id)

        XCTAssertTrue(wasRemoving)
        XCTAssertTrue(duplicateWasRefused)
        XCTAssertFalse(exists(root.appendingPathComponent("dev.test.removing--late")))
        XCTAssertFalse(library.isRemoving(widget.id))
    }

    func testASecondRemovalOfTheSameWidgetIsRefusedWhileTheFirstRuns() async throws {
        let widget = try install("dev.test.twice")
        var secondWasRefused = false
        host.whileStopping = { [unowned self] id in
            do {
                try await self.library.remove(id: id)
            } catch {
                secondWasRefused = (error as? WidgetRuntime.RuntimeError).map(self.isNotRemovable) ?? false
            }
        }

        try await library.remove(id: widget.id)

        XCTAssertTrue(secondWasRefused)
        XCTAssertEqual(host.events.filter { $0.hasPrefix("stop:") }.count, 1)
        XCTAssertFalse(exists(widget.directory))
    }

    // MARK: - Duplicate

    func testDuplicatingLinksTheCopyToThePackageAndRescans() throws {
        let widget = try install("dev.test.duplicate")

        let copy = try library.duplicate(id: widget.id, label: " Work Mail ")

        XCTAssertEqual(copy, "dev.test.duplicate--work-mail")
        let link = root.appendingPathComponent(copy)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            widget.directory.path
        )
        XCTAssertEqual(host.events, ["reload"])
    }

    func testTheCopyStartsWithTheOriginalsPreferences() throws {
        let widget = try install("dev.test.prefs")
        prefs.setSetting(widgetID: widget.id, key: "city", value: .string("Seoul"))
        prefs.setRefreshInterval(90, for: widget.id)
        prefs.setOverride(group: "Work", order: 3, size: "L", for: widget.id)
        prefs.togglePin(widget.id)

        let copy = try library.duplicate(id: widget.id, label: "work")

        XCTAssertEqual(prefs.settings(for: copy)["city"], .string("Seoul"))
        XCTAssertEqual(prefs.refreshIntervals[copy], 90)
        XCTAssertEqual(prefs.override(for: copy)?.group, "Work")
        XCTAssertEqual(prefs.override(for: copy)?.order, 3)
        XCTAssertEqual(prefs.override(for: copy)?.size, "L")
        XCTAssertTrue(prefs.isPinned(copy))
        XCTAssertTrue(prefs.isPinned(widget.id))
    }

    func testAnUnpinnedUnconfiguredOriginalGivesAPlainCopy() throws {
        let widget = try install("dev.test.plain")
        let copy = try library.duplicate(id: widget.id, label: "work")
        XCTAssertTrue(prefs.settings(for: copy).isEmpty)
        XCTAssertNil(prefs.refreshIntervals[copy])
        XCTAssertNil(prefs.override(for: copy))
        XCTAssertFalse(prefs.isPinned(copy))
    }

    func testACopyOfACopyLinksToThePackageUnderThePackagesID() throws {
        let widget = try install("dev.test.chain")
        let first = loadInstance(try library.duplicate(id: widget.id, label: "one"), of: widget)

        let second = try library.duplicate(id: first.id, label: "two")

        XCTAssertEqual(second, "dev.test.chain--two")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(second).path),
            widget.directory.path
        )
    }

    func testANameWithNothingUsableIsRefused() throws {
        let widget = try install("dev.test.empty-label")
        XCTAssertThrowsError(try library.duplicate(id: widget.id, label: " /// ")) { error in
            XCTAssertTrue((error as? WidgetRuntime.RuntimeError).map(self.isInvalidName) ?? false)
        }
        XCTAssertEqual(host.events, [])
    }

    func testANameAlreadyTakenIsRefused() throws {
        let widget = try install("dev.test.taken")
        try library.duplicate(id: widget.id, label: "work")
        XCTAssertThrowsError(try library.duplicate(id: widget.id, label: "Work")) { error in
            XCTAssertTrue((error as? WidgetRuntime.RuntimeError).map(self.isInvalidName) ?? false)
        }
        XCTAssertEqual(host.events, ["reload"], "only the first copy's rescan")
    }

    func testAWidgetOutsideTheRootCannotBeDuplicated() throws {
        let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        let widget = try install("dev.test.dev-checkout", in: elsewhere)
        XCTAssertThrowsError(try library.duplicate(id: widget.id, label: "work")) { error in
            XCTAssertTrue((error as? WidgetRuntime.RuntimeError).map(self.isNotRemovable) ?? false)
        }
        XCTAssertFalse(exists(root.appendingPathComponent("dev.test.dev-checkout--work")))
    }

    func testAnInvalidPackageIDCannotPutALinkOutsideTheRoot() throws {
        let widget = try install("../escape", folder: "escape")
        XCTAssertThrowsError(try library.duplicate(id: widget.id, label: "work")) { error in
            XCTAssertTrue((error as? WidgetRuntime.RuntimeError).map(self.isInvalidName) ?? false)
        }
        XCTAssertFalse(exists(sandbox.appendingPathComponent("escape--work")))
    }

    func testAnUnknownWidgetCannotBeDuplicated() {
        XCTAssertThrowsError(try library.duplicate(id: "dev.test.missing", label: "work")) { error in
            XCTAssertTrue((error as? WidgetRuntime.RuntimeError).map(self.isNotFound) ?? false)
        }
    }
}
