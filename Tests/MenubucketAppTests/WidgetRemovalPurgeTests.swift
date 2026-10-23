import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Requires a disposable Foundation home: never runs against the user's
/// installed widgets. Run separately with CFFIXED_USER_HOME.
@MainActor
final class WidgetRemovalPurgeTests: XCTestCase {
    private final class FailingSecretStore: SecretStoring, @unchecked Sendable {
        let base = InMemorySecretStore()
        func get(widgetId: String, key: String) throws -> String? { try base.get(widgetId: widgetId, key: key) }
        func set(widgetId: String, key: String, value: String) throws {
            try base.set(widgetId: widgetId, key: key, value: value)
        }
        func removeAll(widgetId: String) throws { throw CocoaError(.fileWriteUnknown) }
    }

    func testDuplicatingShortNamedPackageFollowsItsInPlaceUpdate() throws {
        let root = try disposableRoot()
        var (manifest, original) = try installFixture(root: root, name: "short-name-copy")
        let fixture = WidgetRuntime.userWidgetsRoot.appendingPathComponent("short-name-copy")
        try FileManager.default.moveItem(at: original, to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("short-name-prefs.json")))
        runtime.loadWidgets()
        let copy = try runtime.duplicateWidget(id: manifest.id, label: "work")
        let alias = WidgetRuntime.userWidgetsRoot.appendingPathComponent(copy)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, fixture.resolvingSymlinksInPath().path)

        let update = root.appendingPathComponent("short-name-update")
        try FileManager.default.createDirectory(at: update, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: update) }
        manifest.name = "Updated package"
        try JSONEncoder().encode(manifest).write(to: update.appendingPathComponent("widget.json"))
        let candidate = InstallCandidate(manifest: manifest, sourceDirectory: update, permissionSummary: [])
        let destination = try HeadlessInstaller.install(candidate, into: WidgetRuntime.userWidgetsRoot, hostVersion: nil)
        XCTAssertEqual(destination.resolvingSymlinksInPath().path, fixture.resolvingSymlinksInPath().path)
        runtime.loadWidgets()
        for id in [manifest.id, copy] {
            XCTAssertEqual(runtime.widgets.first { $0.id == id }?.manifest.name, "Updated package")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testDuplicatingUsesManifestIdentityAndPreservesForeignIDNamedFolder() throws {
        let root = try disposableRoot()
        let (manifest, original) = try installFixture(root: root, name: "foreign-id-copy")
        let fixture = WidgetRuntime.userWidgetsRoot.appendingPathComponent("foreign-id-copy")
        try FileManager.default.moveItem(at: original, to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: original) }
        var foreign = manifest
        foreign.id = "dev.test.foreign-package"
        let foreignData = try JSONEncoder().encode(foreign)
        try foreignData.write(to: original.appendingPathComponent("widget.json"))
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("foreign-id-prefs.json")))
        runtime.loadWidgets()
        let copy = try runtime.duplicateWidget(id: manifest.id, label: "work")
        let alias = WidgetRuntime.userWidgetsRoot.appendingPathComponent(copy)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, fixture.resolvingSymlinksInPath().path)
        XCTAssertEqual(runtime.widgets.first { $0.id == copy }?.manifest.id, manifest.id)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("widget.json")), foreignData)
    }

    func testDuplicatingInvalidLocalIDCannotCreateAnAliasOutsideWidgetsRoot() throws {
        let root = try disposableRoot()
        var (manifest, fixture) = try installFixture(root: root, name: "invalid-copy-id")
        defer { try? FileManager.default.removeItem(at: fixture) }
        manifest.id = "../invalid-copy-outside-\(UUID().uuidString)"
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        let outside = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id + "--work").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: outside) }
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("invalid-id-prefs.json")))
        runtime.loadWidgets()
        XCTAssertTrue(runtime.widgets.contains { $0.id == manifest.id }, "exercise the manually authored local package")
        XCTAssertThrowsError(try runtime.duplicateWidget(id: manifest.id, label: "work"))
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: outside.path))
        XCTAssertNil(HeadlessInstaller.installedPackages(in: WidgetRuntime.userWidgetsRoot)[manifest.id])
    }

    func testRemovingAnInstancePurgesOnlyItsDataAndKeepsThePackageApproval() async throws {
        let root = try disposableRoot()
        let (manifest, fixture) = try installFixture(root: root, name: "removal-purge")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let permissions = PermissionStore(fileURL: root.appendingPathComponent("test-permissions-purge.json"))
        let secrets = InMemorySecretStore()
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                                    permissionStore: permissions, secretStore: secrets)
        runtime.loadWidgets()
        permissions.approve(manifest)
        let copy = try runtime.duplicateWidget(id: manifest.id, label: "work")
        defer { try? FileManager.default.removeItem(at: WidgetRuntime.userWidgetsRoot.appendingPathComponent(copy)) }

        let storageDirectory = root.appendingPathComponent("storage")
        let seeding = StorageService(directory: storageDirectory)
        for id in [manifest.id, copy] {
            try seeding.set(widgetId: id, key: "value", value: .string(id))
            try secrets.set(widgetId: id, key: "token", value: id)
        }
        defer {
            try? FileManager.default.removeItem(at: storageDirectory.appendingPathComponent(manifest.id + ".json"))
        }

        try await runtime.removeWidget(id: copy)
        XCTAssertFalse(runtime.widgets.contains { $0.id == copy })
        XCTAssertTrue(runtime.widgets.contains { $0.id == manifest.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent(copy + ".json").path))
        XCTAssertEqual(StorageService(directory: storageDirectory).get(widgetId: manifest.id, key: "value"),
                       .string(manifest.id))
        XCTAssertNil(try secrets.get(widgetId: copy, key: "token"))
        XCTAssertEqual(try secrets.get(widgetId: manifest.id, key: "token"), manifest.id)
        XCTAssertEqual(permissions.status(for: manifest), .approved)

        // The last copy goes with its package's decision and data.
        try await runtime.removeWidget(id: manifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent(manifest.id + ".json").path))
        XCTAssertNil(try secrets.get(widgetId: manifest.id, key: "token"))
        XCTAssertEqual(permissions.status(for: manifest), .pending)
    }

    func testFailedPurgeKeepsTheWidgetInstalledAndReportsTheError() async throws {
        let root = try disposableRoot()
        var (manifest, fixture) = try installFixture(root: root, name: "removal-purge-fails")
        defer { try? FileManager.default.removeItem(at: fixture) }
        manifest.entry = .init(kind: "workflow", main: "workflow.json")
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        let workflow = WorkflowDefinition(sources: [:], view: .object(["type": .string("text"), "text": .string("ready")]),
            store: ["resumed": .init(value: .string("new state"))])
        try JSONEncoder().encode(workflow).write(to: fixture.appendingPathComponent("workflow.json"))
        let secrets = FailingSecretStore()
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                                    permissionStore: PermissionStore(fileURL: root.appendingPathComponent("test-permissions-fail.json")),
                                    secretStore: secrets)
        runtime.loadWidgets()
        runtime.permissionStore.approve(manifest)
        try secrets.set(widgetId: manifest.id, key: "token", value: "kept")
        do {
            try await runtime.removeWidget(id: manifest.id)
            XCTFail("removal reported success although the secrets were not erased")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertTrue(runtime.widgets.contains { $0.id == manifest.id })
        XCTAssertEqual(try secrets.get(widgetId: manifest.id, key: "token"), "kept")
        let directory = root.appendingPathComponent("storage")
        let deadline = Date().addingTimeInterval(5)
        while StorageService(directory: directory).get(widgetId: manifest.id, key: "resumed") == nil,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StorageService(directory: directory).get(widgetId: manifest.id, key: "resumed"), .string("new state"),
                       "the surviving widget must be able to save fresh state after the failed removal")
    }

    /// A script's `host.secret.set` is still writing when Remove is chosen:
    /// removal waits for it, then erases what it wrote.
    func testRemovalWaitsForAnInFlightSecretWriteBeforePurging() async throws {
        let root = try disposableRoot()
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.removal-in-flight", name: "In flight",
                                entry: .init(kind: "script", runtime: "deno-ts@1", main: "index.ts"),
                                permissions: .init(keychain: true))
        let fixture = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: fixture)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        try Data().write(to: fixture.appendingPathComponent("index.ts"))
        let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/rpc-stub.sh")
        let permissions = PermissionStore(fileURL: root.appendingPathComponent("test-permissions-in-flight.json"))
        let secrets = BlockingSecretStore()
        let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [stub.path, "secret"]) },
            storage: StorageService(directory: root.appendingPathComponent("test-storage-in-flight")),
            secrets: secrets,
            isApproved: { permissions.status(for: $0) == .approved }
        ), events: RuntimeSupervisorEvents())
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                                    permissionStore: permissions, scriptSupervisor: supervisor, secretStore: secrets)
        runtime.loadWidgets()
        permissions.approve(manifest)
        runtime.refresh(widgetID: manifest.id, manual: true)
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: secrets.entered.wait(timeout: .now() + 5)) }
        }
        XCTAssertEqual(entered, .success, "the script never reached host.secret.set")

        var finished = false
        let removal = Task { @MainActor in
            try await runtime.removeWidget(id: manifest.id)
            finished = true
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(finished, "removal returned while a secret write was still running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        XCTAssertThrowsError(try runtime.duplicateWidget(id: manifest.id, label: "late"))

        secrets.release.signal()
        try await removal.value
        XCTAssertTrue(finished)
        XCTAssertEqual(secrets.events, ["set:\(manifest.id)/token", "removeAll:\(manifest.id)"])
        XCTAssertNil(try secrets.get(widgetId: manifest.id, key: "token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
        let running = await supervisor.isRunning(widgetId: manifest.id)
        XCTAssertFalse(running)
        await supervisor.stopAll()
    }

    /// Holds the first `set` until `release` is signalled, and records the
    /// order of writes and purges.
    private final class BlockingSecretStore: SecretStoring, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let base = InMemorySecretStore()
        private let lock = NSLock()
        private var log: [String] = []
        private var held = false
        var events: [String] { lock.withLock { log } }

        func get(widgetId: String, key: String) throws -> String? { try base.get(widgetId: widgetId, key: key) }
        func set(widgetId: String, key: String, value: String) throws {
            let first = lock.withLock { () -> Bool in defer { held = true }; return !held }
            if first {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            try base.set(widgetId: widgetId, key: key, value: value)
            lock.withLock { log.append("set:\(widgetId)/\(key)") }
        }
        func removeAll(widgetId: String) throws {
            try base.removeAll(widgetId: widgetId)
            lock.withLock { log.append("removeAll:\(widgetId)") }
        }
    }

    private func disposableRoot() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        return WidgetRuntime.applicationSupportDirectory
    }

    private func installFixture(root: URL, name: String) throws -> (Manifest, URL) {
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.\(name)", name: name,
                                entry: .init(kind: "exec"),
                                source: .init(command: ["/usr/bin/true"]),
                                permissions: .init(exec: [.init(command: "/usr/bin/true")], keychain: true,
                                                   storage: .init()))
        let fixture = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: fixture)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        return (manifest, fixture)
    }
}
