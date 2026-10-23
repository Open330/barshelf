import Darwin
import XCTest

@testable import MenubucketCore

final class ExecServiceTests: XCTestCase {
    func testPipeIdentityWitnessDistinguishesIndependentPipes() throws {
        let first = Pipe()
        let second = Pipe()
        defer {
            ExecService.closePipe(first)
            ExecService.closePipe(second)
        }
        let reader = try XCTUnwrap(ExecService.pipeEndpoint(pid: getpid(), descriptor: first.fileHandleForReading.fileDescriptor))
        let writer = try XCTUnwrap(ExecService.pipeEndpoint(pid: getpid(), descriptor: first.fileHandleForWriting.fileDescriptor))
        let other = try XCTUnwrap(ExecService.pipeEndpoint(pid: getpid(), descriptor: second.fileHandleForReading.fileDescriptor))
        XCTAssertEqual(writer.peer, reader.handle)
        XCTAssertEqual(reader.peer, writer.handle)
        XCTAssertNotEqual(reader.handle, other.handle)
    }

    func testCancellationDuringDrainKillsPipeInheritorAfterLeaderExitedNaturally() async throws {
        try await verifyNaturalExitCleanup(cancel: true)
    }

    func testPipeDeadlineKillsInheritorAfterLeaderExitedNaturallyWithoutCancellation() async throws {
        try await verifyNaturalExitCleanup(cancel: false)
    }

    private func verifyNaturalExitCleanup(cancel: Bool) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("The single-process delayed-write fixture requires the macOS system Perl")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A single child ignores TERM, holds the inherited pipes and writes
        // later. No separate sleep process can exit early and release a shell
        // into its side effect while cancellation is being escalated.
        let script = #"""
        (exec /usr/bin/perl -e '$SIG{TERM}="IGNORE"; open(my $r, ">", "ready") or die $!; print {$r} "ready"; close $r; sleep 4; open(my $w, ">", "side-effect") or die $!; print {$w} "escaped";') &
        echo $! > descendant
        echo $$ > leader
        while [ ! -f ready ]; do /bin/sleep 0.01; done
        exit 0
        """#
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["20"]
        unrelated.standardInput = FileHandle.nullDevice
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }
        let unrelatedStart = try XCTUnwrap(ExecService.startTime(of: unrelated.processIdentifier))
        let task = Task {
            let result = await ExecService.capture(command: ["/bin/sh", "-c", script], discover: nil,
                timeoutMs: cancel ? 10_000 : 1_500, workingDirectory: directory)
            try? Data("finished".utf8).write(to: directory.appendingPathComponent("capture-finished"))
            return result
        }
        var descendant: pid_t = 0
        var descendantStart: Date?
        defer {
            task.cancel()
            if descendant > 0, let descendantStart, ExecService.startTime(of: descendant) == descendantStart {
                _ = kill(descendant, SIGKILL)
            }
        }
        func recordedPID(_ name: String) -> pid_t {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let deadline = Date().addingTimeInterval(3)
        var leader: pid_t = 0
        while Date() < deadline {
            descendant = recordedPID("descendant")
            leader = recordedPID("leader")
            if descendant > 0, leader > 0, kill(leader, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(leader, 0)
        XCTAssertNotEqual(kill(leader, 0), 0, "leader must have exited naturally before cancellation")
        descendantStart = try XCTUnwrap(ExecService.startTime(of: descendant))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture-finished").path),
                       "the capture must still be draining its inherited pipe")
        let cancelledAt = Date()
        if cancel {
            task.cancel()
            guard case .failure(.launchFailed("cancelled")) = await task.value else {
                return XCTFail("Expected cancellation while draining the exited leader's pipe")
            }
        } else {
            guard case .failure(.timeout(ms: 1_500)) = await task.value else {
                return XCTFail("Expected the inherited-pipe deadline without explicit cancellation")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2.5)
        // Wait beyond both the SIGKILL grace period and the child's original
        // write deadline, so the old implementation's leak is observable.
        try await Task.sleep(nanoseconds: 4_200_000_000)
        XCTAssertNotEqual(ExecService.startTime(of: descendant), descendantStart)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("side-effect").path))
        XCTAssertEqual(ExecService.startTime(of: unrelated.processIdentifier), unrelatedStart)
        XCTAssertTrue(unrelated.isRunning, "independent process must not be targeted")
    }

    func testCancelledCapturePreventsDelayedSideEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let sideEffect = directory.appendingPathComponent("side-effect")
        let task = Task {
            await ExecService.capture(
                command: ["/bin/sh", "-c", "printf ready > ready; /bin/sleep 1; printf forbidden > side-effect"],
                discover: nil, timeoutMs: 5_000, workingDirectory: directory
            )
        }
        defer { task.cancel() }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "process must launch before cancellation")
        let cancelledAt = Date()
        task.cancel()
        let result = await task.value
        guard case .failure(.launchFailed("cancelled")) = result else {
            return XCTFail("Expected cancellation failure, got \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2.5)
        // Wait past the original command's write, including an inherited pipe.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sideEffect.path))
    }

    func testAlreadyCancelledCaptureNeverLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ExecService.capture(
                command: ["/bin/sh", "-c", "printf forbidden > side-effect"],
                discover: nil, timeoutMs: 5_000, workingDirectory: directory
            )
        }
        guard case .failure(.launchFailed("cancelled")) = await task.value else {
            return XCTFail("Expected cancellation before launch")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("side-effect").path))
    }

    func testCancellationEscalatesForProcessIgnoringTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let task = Task {
            await ExecService.capture(
                command: ["/bin/sh", "-c", "trap '' TERM; printf ready > ready; exec /bin/sleep 20"],
                discover: nil, timeoutMs: 8_000, workingDirectory: directory
            )
        }
        defer { task.cancel() }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let cancelledAt = Date()
        task.cancel()
        guard case .failure(.launchFailed("cancelled")) = await task.value else {
            return XCTFail("Expected cancellation after SIGKILL escalation")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 4)
    }

    func testLaunchdEnvironmentUsesAppLocaleWithoutLeakingHostVariables() throws {
        let environment = ExecService.childEnvironment(
            hostEnvironment: ["HOME": "/tmp/quality", "PRIVATE_TOKEN": "must-not-leak"],
            locale: Locale(identifier: "ko_KR")
        )
        XCTAssertEqual(environment["LANG"], "ko_KR.UTF-8")
        XCTAssertEqual(environment["LC_NUMERIC"], "C")
        XCTAssertEqual(ExecService.childEnvironment(hostEnvironment: [:], locale: Locale(identifier: "ko_US"))["LANG"], "ko_KR.UTF-8")
        XCTAssertNil(environment["PRIVATE_TOKEN"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/date")
        process.arguments = ["-u", "-r", "0", "+%A %b"]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("목요일"), output)
        XCTAssertTrue(output.contains("1월"), output)
    }

    func testExplicitLocaleEnvironmentTakesPrecedence() {
        let environment = ExecService.childEnvironment(
            extraEnvironment: ["LANG": "fr_FR.UTF-8"],
            hostEnvironment: ["LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_TIME": "ja_JP.UTF-8"],
            locale: Locale(identifier: "ko_KR")
        )
        XCTAssertEqual(environment["LANG"], "fr_FR.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["LC_TIME"], "ja_JP.UTF-8")
    }

    /// What the delayed SIGKILL relies on: finding a group's members, and
    /// telling ones that started before the request from a new group that
    /// took over the id.
    func testGroupMembersAndStartTimesAreReadable() {
        XCTAssertTrue(ExecService.groupMembers(getpgrp()).contains(getpid()))
        let started = ExecService.startTime(of: getpid())
        XCTAssertNotNil(started)
        XCTAssertLessThan(started ?? .distantFuture, Date())
        XCTAssertNil(ExecService.startTime(of: 0x7fff_fff0))
    }

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
