import XCTest
@testable import MenubucketApp
import MenubucketCore

final class GalleryTextTests: XCTestCase {
    func testEveryPermissionBecomesASentenceWithAnIcon() {
        let lines = GalleryPermissionText.lines(for: .init(
            exec: ["git", "ssh"],
            keychain: true,
            notifications: true,
            network: ["api.example.com"],
            readPaths: ["~/Downloads"],
            system: ["cpu"]
        ))
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(Set(lines.map(\.symbol)).count, 6)
        XCTAssertTrue(lines.allSatisfy { $0.sentence.hasSuffix(".") && !$0.short.isEmpty })
        XCTAssertTrue(lines[0].sentence.contains("git"))
        XCTAssertTrue(lines[0].sentence.contains("ssh"))
    }

    func testNoPermissionsMeansNoLines() {
        XCTAssertTrue(GalleryPermissionText.lines(for: nil).isEmpty)
        XCTAssertTrue(GalleryPermissionText.lines(for: .init(
            exec: [" "], keychain: false, notifications: false
        )).isEmpty)
    }

    func testRequirementsSplitAndKnownToolsGetAnInstallCommand() {
        let requirements = GalleryRequirementText.requirements(from: "gh CLI + Deno")
        XCTAssertEqual(requirements.map(\.name), ["gh CLI", "Deno"])
        XCTAssertEqual(requirements.map(\.command), ["gh", "deno"])
        XCTAssertEqual(requirements.map(\.installCommand), ["brew install gh", "brew install deno"])

        let unknown = GalleryRequirementText.requirements(from: "muxa CLI")
        XCTAssertEqual(unknown.first?.command, "muxa")
        XCTAssertNil(unknown.first?.installCommand)
        XCTAssertTrue(GalleryRequirementText.requirements(from: nil).isEmpty)
    }
}
