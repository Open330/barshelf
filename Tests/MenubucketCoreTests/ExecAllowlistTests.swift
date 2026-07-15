import XCTest
@testable import MenubucketCore

final class ExecAllowlistTests: XCTestCase {
    private let otpeekPermissions = [
        Manifest.ExecPermission(
            command: "otpeek",
            allowedArgs: [["list", "--json"], ["code", "*", "--json"]],
            maxOutputBytes: 262_144,
            sensitiveOutput: true
        )
    ]

    func testExactArgsMatch() {
        XCTAssertTrue(ExecAllowlist.permits(
            command: ["otpeek", "list", "--json"], permissions: otpeekPermissions
        ))
    }

    func testWildcardMatchesExactlyOneArgument() {
        XCTAssertTrue(ExecAllowlist.permits(
            command: ["otpeek", "code", "acc-123", "--json"], permissions: otpeekPermissions
        ))
        // "*" must not swallow zero or two arguments.
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["otpeek", "code", "--json"], permissions: otpeekPermissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["otpeek", "code", "a", "b", "--json"], permissions: otpeekPermissions
        ))
    }

    func testBlocksUndeclaredSubcommandsAndBinaries() {
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["otpeek", "rm", "acc-123"], permissions: otpeekPermissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["rm", "-rf", "/"], permissions: otpeekPermissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["otpeek", "list", "--json", "--extra"], permissions: otpeekPermissions
        ))
    }

    func testBareDeclarationDoesNotAuthorizeAnotherPath() {
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["/opt/homebrew/bin/otpeek", "list", "--json"],
            permissions: otpeekPermissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["/tmp/evil/not-otpeek", "list", "--json"],
            permissions: otpeekPermissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["./otpeek", "list", "--json"],
            permissions: otpeekPermissions
        ))
    }

    func testNilAllowedArgsAllowsAnyArgs() {
        let permissions = [Manifest.ExecPermission(command: "aas")]
        XCTAssertTrue(ExecAllowlist.permits(command: ["aas", "anything"], permissions: permissions))
        XCTAssertTrue(ExecAllowlist.permits(command: ["aas"], permissions: permissions))
    }

    func testEmptyAllowedArgsAllowsOnlyBareCommand() {
        let permissions = [Manifest.ExecPermission(command: "aas", allowedArgs: [])]
        XCTAssertTrue(ExecAllowlist.permits(command: ["aas"], permissions: permissions))
        XCTAssertFalse(ExecAllowlist.permits(command: ["aas", "usage"], permissions: permissions))
    }

    func testEmptyOrMissingPermissionsBlockEverything() {
        XCTAssertFalse(ExecAllowlist.permits(command: ["ls"], permissions: []))
        XCTAssertFalse(ExecAllowlist.permits(command: ["ls"], permissions: nil))
        XCTAssertFalse(ExecAllowlist.permits(command: [], permissions: otpeekPermissions))
    }

    func testMatchReturnsMatchingEntryMetadata() {
        let matched = ExecAllowlist.match(
            command: ["otpeek", "code", "id-1", "--json"], permissions: otpeekPermissions
        )
        XCTAssertEqual(matched?.sensitiveOutput, true)
        XCTAssertEqual(matched?.maxOutputBytes, 262_144)
    }

    func testRunActionPatternFromContract() {
        // "run": { "command": ["aas","switch","work"] } example from the spec.
        let permissions = [
            Manifest.ExecPermission(
                command: "aas",
                allowedArgs: [["usage", "--json"], ["switch", "*"]]
            )
        ]
        XCTAssertTrue(ExecAllowlist.permits(
            command: ["aas", "switch", "work"], permissions: permissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: ["aas", "logout"], permissions: permissions
        ))
    }
}
