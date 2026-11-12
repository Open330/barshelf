import XCTest
@testable import MenubucketCore

/// An optional source's failure becomes `errors.<id>` the view can branch
/// on; a permission failure never does.
final class WorkflowSourceFailureTests: XCTestCase {
    private let kubectlStderr = """
    aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials.
    E1112 10:06:33 memcache.go:265] "Unhandled Error" err="couldn't get current server API group list: \
    Get \\"https://example.eks.amazonaws.com/api?timeout=8s\\": getting credentials: exec: executable aws failed"
    Unable to connect to the server: getting credentials: exec: executable aws failed with exit code 253
    """

    func testExecFailuresAreClassifiedFromStderr() throws {
        let auth = try XCTUnwrap(WorkflowSourceFailure.classify(
            ExecService.ExecError.nonZeroExit(code: 1, stderr: kubectlStderr)))
        XCTAssertEqual(auth.kind, .auth)
        XCTAssertEqual(auth.code, 1)
        XCTAssertFalse(auth.message.contains("\n"))
        XCTAssertLessThanOrEqual(auth.message.count, WorkflowSourceFailure.messageLimit)

        XCTAssertEqual(WorkflowSourceFailure.classify(ExecService.ExecError.nonZeroExit(
            code: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login"))?.kind, .auth)
        XCTAssertEqual(WorkflowSourceFailure.classify(ExecService.ExecError.nonZeroExit(
            code: 6, stderr: "curl: (6) Could not resolve host: example.com"))?.kind, .offline)
        XCTAssertEqual(WorkflowSourceFailure.classify(ExecService.ExecError.nonZeroExit(
            code: 2, stderr: "boom"))?.kind, .exit)

        let missing = try XCTUnwrap(WorkflowSourceFailure.classify(
            ExecService.ExecError.binaryNotFound(command: "/opt/homebrew/bin/kubectl", searched: [])))
        XCTAssertEqual(missing.kind, .notFound)
        XCTAssertEqual(missing.command, "kubectl")
        XCTAssertEqual(WorkflowSourceFailure.classify(ExecService.ExecError.timeout(ms: 8000))?.kind, .timeout)
    }

    func testHTTPAndNetworkFailures() {
        XCTAssertEqual(WorkflowSourceFailure.classify(HttpSource.HttpSourceError.httpStatus(429))?.kind, .rateLimited)
        XCTAssertEqual(WorkflowSourceFailure.classify(HttpSource.HttpSourceError.httpStatus(401))?.kind, .auth)
        XCTAssertEqual(WorkflowSourceFailure.classify(HttpSource.HttpSourceError.httpStatus(404))?.kind, .notFound)
        XCTAssertEqual(WorkflowSourceFailure.classify(HttpSource.HttpSourceError.httpStatus(503))?.code, 503)
        XCTAssertEqual(WorkflowSourceFailure.classify(URLError(.notConnectedToInternet))?.kind, .offline)
        XCTAssertEqual(WorkflowSourceFailure.classify(URLError(.timedOut))?.kind, .timeout)
        XCTAssertEqual(WorkflowSourceFailure.classify(FileSource.FileSourceError.notADirectory("/x"))?.kind, .notFound)
        XCTAssertEqual(WorkflowSourceFailure.classify(NSError(domain: NSCocoaErrorDomain, code: 3840))?.kind, .invalid)
    }

    func testPermissionAndMalformedSourcesStillFail() {
        XCTAssertNil(WorkflowSourceFailure.classify(FileSource.FileSourceError.unauthorizedPath("/etc")))
        XCTAssertNil(WorkflowSourceFailure.classify(HttpSource.HttpSourceError.notHTTPS("http://x")))
        XCTAssertNil(WorkflowSourceFailure.classify(ExecService.ExecError.emptyCommand))
        XCTAssertNil(WorkflowSourceFailure.classify(CancellationError()))
    }

    func testOptionalDecodesAndErrorsReachTheView() throws {
        let definition = try WorkflowDefinition.decode(from: Data("""
        {"schemaVersion":1,
         "sources":{"data":{"use":"http","optional":true,"with":{"url":"https://example.com"}},
                    "other":{"use":"value","with":{"n":1}}},
         "view":{"type":"text","text":"${coalesce(errors.data.kind, 'ok')}/${coalesce(errors.other, 'none')}"}}
        """.utf8))
        XCTAssertEqual(definition.sources["data"]?.optional, true)
        XCTAssertNil(definition.sources["other"]?.optional)

        let failed = try WorkflowEngine.evaluate(
            definition, sources: ["data": .null, "other": .object(["n": .number(1)])], settings: .object([:]),
            errors: ["data": WorkflowSourceFailure(kind: .offline, message: "offline").value]
        )
        XCTAssertEqual(failed.viewTree.text, "offline/none")

        let fine = try WorkflowEngine.evaluate(
            definition, sources: ["data": .object([:]), "other": .object([:])], settings: .object([:])
        )
        XCTAssertEqual(fine.viewTree.text, "ok/none")
    }

    func testTheGenericEmptyNeverCoversAFailedSource() throws {
        let definition = try WorkflowDefinition.decode(from: Data("""
        {"schemaVersion":1,
         "sources":{"data":{"use":"http","optional":true,"with":{"url":"https://example.com"}}},
         "view":{"type":"vstack","children":
           {"forEach":"sources.data.items","as":"row","template":{"type":"text","text":"${row.name}"}}},
         "empty":{"type":"empty","title":"Nothing here"}}
        """.utf8))
        let failed = try WorkflowEngine.evaluate(
            definition, sources: ["data": .null], settings: .object([:]),
            errors: ["data": WorkflowSourceFailure(kind: .offline, message: "offline").value]
        )
        XCTAssertFalse(failed.usedEmpty)
        XCTAssertEqual(failed.viewTree.type, "vstack")

        let nothing = try WorkflowEngine.evaluate(
            definition, sources: ["data": .object(["items": .array([])])], settings: .object([:])
        )
        XCTAssertTrue(nothing.usedEmpty)
    }
}
