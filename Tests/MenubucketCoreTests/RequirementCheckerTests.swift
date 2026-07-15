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
}
