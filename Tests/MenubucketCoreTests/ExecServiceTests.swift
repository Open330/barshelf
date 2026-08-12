import XCTest

@testable import MenubucketCore

final class ExecServiceTests: XCTestCase {
    func testDiscoveryRejectsExecutableWithDifferentBareCommandIdentity() {
        var searched: [String] = []

        let resolved = ExecService.resolveExecutable(
            command0: "git",
            discover: ["/bin/sh"],
            workingDirectory: nil,
            searched: &searched
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(searched, ["/bin/sh"])
    }

    func testDiscoveryAcceptsExecutableWithMatchingBareCommandIdentity() throws {
        var searched: [String] = []

        let resolved = ExecService.resolveExecutable(
            command0: "sh",
            discover: ["/bin/sh"],
            workingDirectory: nil,
            searched: &searched
        )

        XCTAssertEqual(try XCTUnwrap(resolved).path, "/bin/sh")
    }

    func testDiscoveryRejectsBareCommandSymlinkedToDifferentExecutableIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/bin/sh")
        var searched: [String] = []

        let resolved = ExecService.resolveExecutable(
            command0: "git",
            discover: [symlink.path],
            workingDirectory: nil,
            searched: &searched
        )

        XCTAssertNil(resolved)
    }

    func testIdentityAcceptsTrustedPATHAliasWithDifferentCanonicalBasename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/bin/sh")

        XCTAssertTrue(ExecService.executableMatchesCommandIdentity(
            command0: "python3",
            candidate: symlink,
            workingDirectory: nil,
            trustedBareCommand: URL(fileURLWithPath: "/bin/sh")
        ))
    }

    func testIdentityRejectsAliasThatDiffersFromTrustedPATHExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/bin/sh")

        XCTAssertFalse(ExecService.executableMatchesCommandIdentity(
            command0: "git",
            candidate: symlink,
            workingDirectory: nil,
            trustedBareCommand: URL(fileURLWithPath: "/usr/bin/git")
        ))
    }

    func testIdentityRejectsCandidateWhosePresentedNameDiffers() {
        XCTAssertFalse(ExecService.executableMatchesCommandIdentity(
            command0: "git",
            candidate: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: nil,
            trustedBareCommand: URL(fileURLWithPath: "/bin/sh")
        ))
    }

    func testIdentityAcceptsOrdinarySameCanonicalBasename() {
        XCTAssertTrue(ExecService.executableMatchesCommandIdentity(
            command0: "sh",
            candidate: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: nil,
            trustedBareCommand: nil
        )
        )
    }

    func testDiscoveryRejectsCandidateForDifferentPathCommandIdentity() {
        var searched: [String] = []

        let resolved = ExecService.resolveExecutable(
            command0: "/usr/bin/git",
            discover: ["/bin/sh"],
            workingDirectory: nil,
            searched: &searched
        )

        XCTAssertNil(resolved)
    }

    func testDiscoveryAcceptsSymlinkForSamePathCommandIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appendingPathComponent("sh")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: "/bin/sh")
        var searched: [String] = []

        let resolved = ExecService.resolveExecutable(
            command0: "/bin/sh",
            discover: [symlink.path],
            workingDirectory: nil,
            searched: &searched
        )

        XCTAssertEqual(
            try XCTUnwrap(resolved).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: "/bin/sh").resolvingSymlinksInPath().path
        )
    }
}
