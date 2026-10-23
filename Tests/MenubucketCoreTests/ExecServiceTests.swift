import XCTest

@testable import MenubucketCore

final class ExecServiceTests: XCTestCase {
    /// The command exits on SIGTERM but leaves a descendant that ignores it;
    /// the SIGKILL that follows goes to the whole group, so nothing the
    /// command started is left running after cancel, revoke or timeout.
    func testCancellationKillsDescendantThatIgnoresTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant")
        let task = Task {
            await ExecService.capture(
                command: ["/bin/sh", "-c", "(trap '' TERM; exec /bin/sleep 30) & echo $! > descendant; wait"],
                discover: nil, timeoutMs: 10_000, workingDirectory: directory
            )
        }
        var descendant: pid_t = 0
        let readyDeadline = Date().addingTimeInterval(3)
        while descendant == 0, Date() < readyDeadline {
            let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
            descendant = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if descendant == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertNotEqual(descendant, 0, "descendant must start before cancellation")
        defer { if descendant != 0 { kill(descendant, SIGKILL) } }
        task.cancel()
        _ = await task.value
        // SIGTERM ends the shell at once; the group's SIGKILL follows 2 s later.
        let deadline = Date().addingTimeInterval(4)
        while kill(descendant, 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotEqual(kill(descendant, 0), 0, "descendant ignoring SIGTERM must not outlive cancellation")
    }

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
