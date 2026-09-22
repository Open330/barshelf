import XCTest
@testable import MenubucketCore

final class RequirementCheckerTests: XCTestCase {
    func testSingleDependencyExtraction() {
        XCTAssertEqual(RequirementChecker.candidateBinaries(from: "Deno runtime"), ["Deno", "deno"])
        XCTAssertEqual(RequirementChecker.candidateBinaries(from: "aas CLI"), ["aas"])
    }

    func testCompoundDependenciesRemainSeparateRequirements() {
        XCTAssertEqual(
            RequirementChecker.candidateGroups(from: "muxa CLI + Deno runtime"),
            [["muxa"], ["Deno", "deno"]]
        )
        XCTAssertEqual(
            RequirementChecker.candidateGroups(from: "gh CLI + Deno"),
            [["gh"], ["Deno", "deno"]]
        )
    }

    func testNoiseOnlyRequirementIsUnknown() {
        let checker = RequirementChecker()
        XCTAssertEqual(checker.status(forRequires: "CLI runtime"), .unknown)
    }

    func testInvalidatingCacheFindsCommandInstalledAfterFirstProbe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-requirements-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checker = RequirementChecker(searchDirectories: { [directory.path] })

        XCTAssertEqual(checker.status(forRequires: "fixture-cli CLI"), .missing)

        let executable = directory.appendingPathComponent("fixture-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        // The first result is memoized until an explicit gallery recheck.
        XCTAssertEqual(checker.status(forRequires: "fixture-cli CLI"), .missing)
        checker.invalidateCache()
        XCTAssertEqual(checker.status(forRequires: "fixture-cli CLI"), .satisfied)
    }
}
