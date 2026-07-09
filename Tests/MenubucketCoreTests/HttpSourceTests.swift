import XCTest
@testable import MenubucketCore

/// Stub URLProtocol so the http source is exercised without real networking.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        var statusCode = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    nonisolated(unsafe) static var stub: Stub = Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let url = request.url ?? URL(string: "https://example.test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: Self.stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HttpSourceTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.stub = MockURLProtocol.Stub()
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testFetchDecodesJSONAndSendsAcceptHeader() async throws {
        MockURLProtocol.stub.body = Data(#"{"temp": 21.5, "city": "Seoul"}"#.utf8)
        let value = try await HttpSource.fetch(
            HttpSource.Params(url: "https://api.example.test/weather"),
            session: makeSession()
        )
        XCTAssertEqual(value.objectValue?["temp"]?.numberValue, 21.5)
        XCTAssertEqual(value.objectValue?["city"]?.stringValue, "Seoul")
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    func testCustomHeadersOverrideDefault() async throws {
        MockURLProtocol.stub.body = Data("{}".utf8)
        _ = try await HttpSource.fetch(
            HttpSource.Params(url: "https://api.example.test", headers: ["Accept": "text/plain"]),
            session: makeSession()
        )
        XCTAssertEqual(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"),
            "text/plain"
        )
    }

    func testRejectsNonHTTPSBeforeAnyRequest() async {
        do {
            _ = try await HttpSource.fetch(
                HttpSource.Params(url: "http://api.example.test"),
                session: makeSession()
            )
            XCTFail("expected notHTTPS")
        } catch let error as HttpSource.HttpSourceError {
            XCTAssertEqual(error, .notHTTPS("http://api.example.test"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(MockURLProtocol.lastRequest) // never hit the network
    }

    func testMissingURLThrows() {
        XCTAssertThrowsError(try HttpSource.Params(from: .object([:]))) { error in
            XCTAssertEqual(error as? HttpSource.HttpSourceError, .missingURL)
        }
    }

    func testNon2xxStatusThrows() async {
        MockURLProtocol.stub.statusCode = 503
        MockURLProtocol.stub.body = Data("{}".utf8)
        do {
            _ = try await HttpSource.fetch(
                HttpSource.Params(url: "https://api.example.test"),
                session: makeSession()
            )
            XCTFail("expected httpStatus")
        } catch let error as HttpSource.HttpSourceError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInvalidJSONThrows() async {
        MockURLProtocol.stub.body = Data("not json".utf8)
        do {
            _ = try await HttpSource.fetch(
                HttpSource.Params(url: "https://api.example.test"),
                session: makeSession()
            )
            XCTFail("expected invalidJSON")
        } catch let error as HttpSource.HttpSourceError {
            guard case .invalidJSON = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - `network` permission kind

    func testManifestDeclaresNetwork() {
        let withNetwork = Manifest(
            schemaVersion: 1, id: "x", name: "X",
            entry: .init(kind: "workflow"),
            permissions: .init(network: ["api.example.test"])
        )
        XCTAssertTrue(PermissionStore.manifestDeclares(.network, in: withNetwork))

        let withoutNetwork = Manifest(
            schemaVersion: 1, id: "x", name: "X", entry: .init(kind: "workflow")
        )
        XCTAssertFalse(PermissionStore.manifestDeclares(.network, in: withoutNetwork))

        let emptyNetwork = Manifest(
            schemaVersion: 1, id: "x", name: "X",
            entry: .init(kind: "workflow"), permissions: .init(network: [])
        )
        XCTAssertFalse(PermissionStore.manifestDeclares(.network, in: emptyNetwork))
    }
}
