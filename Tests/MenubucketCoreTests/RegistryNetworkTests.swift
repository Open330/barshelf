import XCTest
@testable import MenubucketCore

private final class RegistryNetworkProtocol: URLProtocol {
    /// What the next request answers with. The URL loading system calls the
    /// protocol on its own threads while the test sets this up and tears it
    /// down on another, so every read and write goes through the lock: a
    /// late `stopLoading` used to race `tearDown` clearing `stopped`
    /// (reported by the weekly thread sanitizer run).
    private struct Stub {
        var body = Data()
        var contentLength: Int?
        var keepOpen = false
        var stopped: XCTestExpectation?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()

    private static func withStub<T>(_ body: (inout Stub) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&stub)
    }

    static var body: Data {
        get { withStub { $0.body } }
        set { withStub { $0.body = newValue } }
    }
    static var contentLength: Int? {
        get { withStub { $0.contentLength } }
        set { withStub { $0.contentLength = newValue } }
    }
    static var keepOpen: Bool {
        get { withStub { $0.keepOpen } }
        set { withStub { $0.keepOpen = newValue } }
    }
    static var stopped: XCTestExpectation? {
        get { withStub { $0.stopped } }
        set { withStub { $0.stopped = newValue } }
    }
    static func reset() { withStub { $0 = Stub() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, contentLength, keepOpen) = Self.withStub { ($0.body, $0.contentLength, $0.keepOpen) }
        let headers = contentLength.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        if !keepOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    // Fulfilled outside the lock: the expectation has its own.
    override func stopLoading() { Self.stopped?.fulfill() }
}

final class RegistryNetworkTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryNetworkProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        RegistryNetworkProtocol.reset()
        super.tearDown()
    }

    func testSmallRegistryResponseIsPreserved() async throws {
        let expected = Data(#"{"schemaVersion":1,"widgets":[]}"#.utf8)
        RegistryNetworkProtocol.body = expected
        let session = session()
        defer { session.invalidateAndCancel() }
        let actual = try await RegistryClient.fetchIndex(from: URL(string: "https://registry.example.test/index.json")!,
                                                         session: session)
        XCTAssertEqual(actual, expected)
    }

    func testAdvertisedOversizeCancelsBeforeServerFinishesResponse() async {
        RegistryNetworkProtocol.contentLength = RegistryClient.maxResponseBytes + 1
        RegistryNetworkProtocol.body = Data(repeating: 0, count: 8192)
        await assertOversizeIsCancelled()
    }

    func testUnknownLengthOversizeCancelsWhileServerKeepsConnectionOpen() async {
        RegistryNetworkProtocol.body = Data(repeating: UInt8(ascii: "x"), count: RegistryClient.maxResponseBytes + 1)
        await assertOversizeIsCancelled()
    }

    private func assertOversizeIsCancelled() async {
        RegistryNetworkProtocol.keepOpen = true
        let rejected = expectation(description: "size limit rejects unfinished response")
        let stopped = expectation(description: "underlying network task is cancelled")
        stopped.assertForOverFulfill = false
        RegistryNetworkProtocol.stopped = stopped
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = Task {
            do {
                _ = try await RegistryClient.fetchIndex(from: URL(string: "https://registry.example.test/index.json")!,
                                                         session: session)
                XCTFail("oversized response must fail")
            } catch {
                XCTAssertEqual(error as? RegistryError, .responseTooLarge(limitBytes: RegistryClient.maxResponseBytes))
            }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected, stopped], timeout: 10)
        request.cancel()
        await request.value
    }
}
