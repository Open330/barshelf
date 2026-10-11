import XCTest
@testable import MenubucketCore

private final class RegistryNetworkProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var contentLength: Int?
    nonisolated(unsafe) static var keepOpen = false
    nonisolated(unsafe) static var stopped: XCTestExpectation?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = Self.contentLength.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.body.isEmpty { client?.urlProtocol(self, didLoad: Self.body) }
        if !Self.keepOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.stopped?.fulfill() }
}

final class RegistryNetworkTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistryNetworkProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        RegistryNetworkProtocol.body = Data()
        RegistryNetworkProtocol.contentLength = nil
        RegistryNetworkProtocol.keepOpen = false
        RegistryNetworkProtocol.stopped = nil
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
