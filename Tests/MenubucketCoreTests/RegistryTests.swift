import XCTest
@testable import MenubucketCore

final class RegistryTests: XCTestCase {
    // MARK: Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let validIndexJSON = """
    {
      "schemaVersion": 1,
      "name": "test registry",
      "updatedAt": "2026-07-08T00:00:00Z",
      "widgets": [
        {
          "id": "dev.example.one",
          "name": "One",
          "description": "First widget",
          "version": "1.2.3",
          "author": "tester",
          "icon": "gauge",
          "kind": "exec",
          "tags": ["dev", "ai"],
          "install": { "url": "https://github.com/owner/repo/tree/main/widgets/one", "bundled": "one" },
          "permissions": { "exec": ["one-cli"], "keychain": true, "notifications": false },
          "homepage": "https://example.com"
        },
        {
          "id": "dev.example.two",
          "name": "Two",
          "kind": "script",
          "install": { "url": "https://example.com/two.mbw" }
        }
      ]
    }
    """

    private func write(_ json: String, name: String = "index.json") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func makeClient(
        env: [String: String] = [:],
        remote: URL? = nil,
        bundled: [URL] = [],
        cacheMaxAge: TimeInterval = 24 * 60 * 60,
        fetch: @escaping RegistryClient.Fetcher = { _ in
            throw RegistryError.fileNotFound("no fetcher configured")
        }
    ) -> RegistryClient {
        RegistryClient(configuration: RegistryClient.Configuration(
            environment: env,
            defaultRemoteURL: remote,
            bundledFallbacks: bundled,
            cacheDirectory: tempDir.appendingPathComponent("cache", isDirectory: true),
            cacheMaxAge: cacheMaxAge,
            fetch: fetch
        ))
    }

    // MARK: Parsing

    func testParsesValidIndex() throws {
        let (index, warnings) = try RegistryIndex.parse(Data(Self.validIndexJSON.utf8))

        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.name, "test registry")
        XCTAssertEqual(index.updatedAt, "2026-07-08T00:00:00Z")
        XCTAssertEqual(index.widgets.count, 2)

        let first = index.widgets[0]
        XCTAssertEqual(first.id, "dev.example.one")
        XCTAssertEqual(first.name, "One")
        XCTAssertEqual(first.description, "First widget")
        XCTAssertEqual(first.version, "1.2.3")
        XCTAssertEqual(first.icon, "gauge")
        XCTAssertEqual(first.kind, "exec")
        XCTAssertEqual(first.tags, ["dev", "ai"])
        XCTAssertEqual(first.install.url, "https://github.com/owner/repo/tree/main/widgets/one")
        XCTAssertEqual(first.install.bundled, "one")
        XCTAssertEqual(first.permissions?.exec, ["one-cli"])
        XCTAssertEqual(first.permissions?.keychain, true)
        XCTAssertEqual(first.permissions?.notifications, false)
        XCTAssertEqual(first.homepage, "https://example.com")

        // Optional fields absent on a minimal entry.
        let second = index.widgets[1]
        XCTAssertEqual(second.id, "dev.example.two")
        XCTAssertNil(second.description)
        XCTAssertNil(second.permissions)
    }

    func testSkipsBrokenEntriesWithWarnings() throws {
        let json = """
        {
          "schemaVersion": 1,
          "widgets": [
            { "id": "dev.ok.a", "name": "A", "install": { "url": "https://example.com/a.zip" } },
            { "id": "dev.broken.no-name", "install": { "url": "https://example.com/b.zip" } },
            { "id": "dev.broken.no-install", "name": "C" },
            "not-an-object",
            { "id": "", "name": "EmptyID", "install": { "url": "https://example.com/d.zip" } },
            { "id": "dev.broken.empty-url", "name": "E", "install": { "url": "  " } },
            { "id": "dev.ok.f", "name": "F", "install": { "url": "https://example.com/f.zip" } }
          ]
        }
        """
        let (index, warnings) = try RegistryIndex.parse(Data(json.utf8))

        XCTAssertEqual(index.widgets.map(\.id), ["dev.ok.a", "dev.ok.f"])
        // 5 broken entries → 5 warnings.
        XCTAssertEqual(warnings.count, 5)
        XCTAssertTrue(warnings.contains { $0.contains("name") })
        XCTAssertTrue(warnings.contains { $0.contains("install") })
        XCTAssertTrue(warnings.contains { $0.contains("empty id") })
        XCTAssertTrue(warnings.contains { $0.contains("empty install.url") })
    }

    func testRejectsWrongSchemaVersion() {
        let json = """
        { "schemaVersion": 2, "widgets": [] }
        """
        XCTAssertThrowsError(try RegistryIndex.parse(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? RegistryError, .unsupportedSchemaVersion(2)
            )
        }
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try RegistryIndex.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try RegistryIndex.parse(Data("{}".utf8))) // no schemaVersion
    }

    func testShippedSampleIndexParses() throws {
        // repo-root registry/index.json — the sample this repo serves.
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("registry/index.json")
        let (index, warnings) = try RegistryIndex.parse(Data(contentsOf: sample))
        XCTAssertEqual(index.schemaVersion, 1)
        XCTAssertEqual(index.widgets.count, 16)
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertEqual(
            Set(index.widgets.compactMap(\.kind)),
            ["exec", "script", "workflow"]
        )
        // R07: CLI/runtime-dependent entries carry the display-only
        // `requires` badge; the CLI-free starters do not.
        let byID = Dictionary(uniqueKeysWithValues: index.widgets.map { ($0.id, $0) })
        XCTAssertEqual(byID["dev.barshelf.aas-usage"]?.requires, "aas CLI")
        XCTAssertEqual(byID["dev.barshelf.otpeek"]?.requires, "otpeek CLI")
        XCTAssertEqual(byID["dev.barshelf.clock-script"]?.requires, "Deno runtime")
        XCTAssertNil(byID["dev.barshelf.hello"]?.requires)
        XCTAssertNil(byID["dev.barshelf.recent-files"]?.requires)
        XCTAssertNil(byID["dev.barshelf.local-time"]?.requires)
        XCTAssertEqual(byID["dev.barshelf.battery"]?.requires, "Deno runtime")
        XCTAssertEqual(byID["dev.barshelf.top-processes"]?.requires, "Deno runtime")
        // Origin-project links surfaced per user feedback (Stashbar / aas).
        XCTAssertEqual(
            byID["dev.barshelf.recent-files"]?.homepage,
            "https://github.com/jiunbae/stashbar"
        )
        XCTAssertEqual(
            byID["dev.barshelf.aas-usage"]?.homepage,
            "https://github.com/Open330/aas"
        )
        XCTAssertEqual(byID["dev.barshelf.hello"]?.install.bundled, "hello")
        XCTAssertEqual(byID["dev.barshelf.recent-files"]?.install.bundled, "recent-files")
        XCTAssertEqual(byID["dev.barshelf.aas-usage"]?.install.bundled, "aas-usage")
        XCTAssertEqual(byID["dev.barshelf.otpeek"]?.install.bundled, "otpeek")
        XCTAssertEqual(byID["dev.barshelf.clock-script"]?.install.bundled, "clock-script")
        XCTAssertEqual(
            byID["dev.barshelf.recent-files"]?.install.url,
            "https://github.com/jiunbae/stashbar"
        )
        XCTAssertEqual(
            byID["dev.barshelf.aas-usage"]?.install.url,
            "https://github.com/Open330/aas"
        )
    }

    // MARK: Resolution order

    func testEnvironmentLocalPathWins() async throws {
        let file = try write(Self.validIndexJSON, name: "env-index.json")
        let client = makeClient(
            env: ["BARSHELF_REGISTRY": file.path],
            remote: URL(string: "https://unreachable.example/index.json"),
            fetch: { _ in
                XCTFail("remote must not be fetched when env path works")
                throw RegistryError.fileNotFound("unexpected")
            }
        )
        let result = try await client.load()
        XCTAssertEqual(result.source, .environmentFile(file.path))
        XCTAssertEqual(result.index.widgets.count, 2)
    }

    func testEnvironmentRemoteURLIsFetched() async throws {
        let envURL = URL(string: "https://env.example/index.json")!
        let client = makeClient(
            env: ["BARSHELF_REGISTRY": envURL.absoluteString],
            remote: URL(string: "https://default.example/index.json"),
            fetch: { url in
                XCTAssertEqual(url, envURL)
                return Data(Self.validIndexJSON.utf8)
            }
        )
        let result = try await client.load()
        XCTAssertEqual(result.source, .remote(envURL))
    }

    func testBrokenEnvironmentFallsBackToRemote() async throws {
        let remote = URL(string: "https://default.example/index.json")!
        let client = makeClient(
            env: ["BARSHELF_REGISTRY": tempDir.appendingPathComponent("missing.json").path],
            remote: remote,
            fetch: { _ in Data(Self.validIndexJSON.utf8) }
        )
        let result = try await client.load()
        XCTAssertEqual(result.source, .remote(remote))
        XCTAssertTrue(result.warnings.contains { $0.contains("BARSHELF_REGISTRY") })
    }

    func testLegacyEnvironmentVariableStillWorks() async throws {
        let file = try write(Self.validIndexJSON, name: "legacy-env-index.json")
        let client = makeClient(env: ["MENUBUCKET_REGISTRY": file.path])
        let result = try await client.load()
        XCTAssertEqual(result.source, .environmentFile(file.path))
    }

    func testRemoteFailureFallsBackToBundled() async throws {
        let bundled = try write(Self.validIndexJSON, name: "bundled.json")
        let client = makeClient(
            remote: URL(string: "https://down.example/index.json"),
            bundled: [
                tempDir.appendingPathComponent("does-not-exist.json"),
                bundled,
            ],
            fetch: { url in throw RegistryError.httpStatus(500, url) }
        )
        let result = try await client.load()
        XCTAssertEqual(result.source, .bundled(bundled))
        XCTAssertEqual(result.index.widgets.count, 2)
    }

    func testAllSourcesFailingThrows() async {
        let client = makeClient(
            remote: URL(string: "https://down.example/index.json"),
            bundled: [tempDir.appendingPathComponent("nope.json")],
            fetch: { url in throw RegistryError.httpStatus(500, url) }
        )
        do {
            _ = try await client.load()
            XCTFail("expected allSourcesFailed")
        } catch let RegistryError.allSourcesFailed(details) {
            XCTAssertFalse(details.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Caching

    func testSecondLoadServedFromCache() async throws {
        let remote = URL(string: "https://cached.example/index.json")!
        let counter = FetchCounter()
        let client = makeClient(remote: remote, fetch: { _ in
            counter.increment()
            return Data(Self.validIndexJSON.utf8)
        })

        let first = try await client.load()
        XCTAssertEqual(first.source, .remote(remote))
        let second = try await client.load()
        XCTAssertEqual(second.source, .cache(remote))
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(second.index.widgets.count, 2)
    }

    func testForceRefreshBypassesCache() async throws {
        let remote = URL(string: "https://cached.example/index.json")!
        let counter = FetchCounter()
        let client = makeClient(remote: remote, fetch: { _ in
            counter.increment()
            return Data(Self.validIndexJSON.utf8)
        })

        _ = try await client.load()
        let refreshed = try await client.load(forceRefresh: true)
        XCTAssertEqual(refreshed.source, .remote(remote))
        XCTAssertEqual(counter.count, 2)
    }

    func testExpiredCacheRefetches() async throws {
        let remote = URL(string: "https://stale.example/index.json")!
        let counter = FetchCounter()
        let client = makeClient(
            remote: remote,
            cacheMaxAge: 0.05,
            fetch: { _ in
                counter.increment()
                return Data(Self.validIndexJSON.utf8)
            }
        )

        _ = try await client.load()
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try await client.load()
        XCTAssertEqual(second.source, .remote(remote))
        XCTAssertEqual(counter.count, 2)
    }

    func testFetchFailureFallsBackToStaleCache() async throws {
        let remote = URL(string: "https://flaky.example/index.json")!
        let counter = FetchCounter()
        let client = makeClient(
            remote: remote,
            cacheMaxAge: 0.05,
            fetch: { url in
                counter.increment()
                if counter.count == 1 {
                    return Data(Self.validIndexJSON.utf8)
                }
                throw RegistryError.httpStatus(500, url)
            }
        )

        _ = try await client.load()
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try await client.load()
        XCTAssertEqual(second.source, .cache(remote))
        XCTAssertEqual(second.index.widgets.count, 2)
        XCTAssertTrue(second.warnings.contains { $0.contains("refresh failed") })
    }

    func testCacheFileNamesAreDistinctPerURL() {
        let client = makeClient()
        let a = client.cacheFileURL(for: URL(string: "https://a.example/index.json")!)
        let b = client.cacheFileURL(for: URL(string: "https://b.example/index.json")!)
        XCTAssertNotEqual(a, b)
    }

    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }
    }
}
