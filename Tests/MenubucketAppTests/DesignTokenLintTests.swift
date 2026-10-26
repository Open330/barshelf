import Foundation
import XCTest

/// Keeps spacing, corners, opacities, point sizes and animation curves coming
/// from `DesignTokens` instead of literals typed into a view. Files that
/// still hold literals are listed in `design-literal-baseline.json` with how
/// many; a file may only go down. Run with `UPDATE_DESIGN_BASELINE=1` after
/// moving a file onto tokens to record its new, lower count.
final class DesignTokenLintTests: XCTestCase {
    /// What counts as a literal design decision. Zero is not one (`spacing: 0`
    /// means "touching"), and neither is a value computed from a token.
    static let patterns: [(name: String, regex: String)] = [
        ("padding", #"\.padding\((?:\.[a-zA-Z]+,\s*)?-?(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]+)\)"#),
        ("spacing", #"spacing:\s*(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]+)\b"#),
        ("cornerRadius", #"cornerRadius:\s*(?:[1-9][0-9]*(?:\.[0-9]+)?|0\.[0-9]+)\b"#),
        ("pointSize", #"\.system\(size:\s*[0-9]"#),
        ("opacity", #"\.opacity\([^)\n]*\b0?\.[0-9]+"#),
        ("animation", #"\.(?:easeInOut|easeOut|easeIn|linear|snappy|smooth|bouncy)\(|\.spring\((?:response|duration):"#),
    ]

    /// Where the tokens themselves are defined.
    static let exempt: Set<String> = ["Sources/MenubucketApp/Design/DesignTokens.swift"]

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var baselineURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/design-literal-baseline.json")
    }

    static func countLiterals(in source: String) -> Int {
        // Comments explain values; they are not values.
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                // `://` is a URL in a string, not a comment.
                guard let range = line.range(of: #"(?<!:)//"#, options: .regularExpression) else { return line }
                return line[..<range.lowerBound]
            }
            .joined(separator: "\n")
        return patterns.reduce(0) { total, pattern in
            let regex = try! NSRegularExpression(pattern: pattern.regex)
            return total + regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
        }
    }

    private func currentCounts() throws -> [String: Int] {
        let root = Self.repoRoot
        var counts: [String: Int] = [:]
        for directory in ["Sources/MenubucketApp", "WidgetExtension"] {
            let base = root.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                guard !Self.exempt.contains(relative) else { continue }
                let count = Self.countLiterals(in: try String(contentsOf: url, encoding: .utf8))
                if count > 0 { counts[relative] = count }
            }
        }
        return counts
    }

    func testNoNewDesignLiterals() throws {
        let counts = try currentCounts()
        if ProcessInfo.processInfo.environment["UPDATE_DESIGN_BASELINE"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
            try (data + Data("\n".utf8)).write(to: Self.baselineURL)
            return
        }
        let baseline = try JSONDecoder().decode(
            [String: Int].self, from: Data(contentsOf: Self.baselineURL)
        )
        for (file, count) in counts.sorted(by: { $0.key < $1.key }) {
            let allowed = baseline[file] ?? 0
            XCTAssertLessThanOrEqual(
                count, allowed,
                "\(file) has \(count) literal spacing/radius/opacity/size/animation values (allowed \(allowed)). Use Spacing, Radius, Fill, Motion or Typography from DesignTokens.swift."
            )
        }
        for (file, allowed) in baseline.sorted(by: { $0.key < $1.key }) {
            let count = counts[file] ?? 0
            XCTAssertGreaterThanOrEqual(
                count, allowed,
                "\(file) is down to \(count) literals from \(allowed) — record it with UPDATE_DESIGN_BASELINE=1 so it cannot creep back."
            )
        }
    }

    func testThePatternsCatchLiteralsAndSkipTokens() {
        XCTAssertEqual(Self.countLiterals(in: ".padding(10)"), 1)
        XCTAssertEqual(Self.countLiterals(in: ".padding(.horizontal, 6)"), 1)
        XCTAssertEqual(Self.countLiterals(in: "VStack(spacing: 6) {"), 1)
        XCTAssertEqual(Self.countLiterals(in: "RoundedRectangle(cornerRadius: 8)"), 1)
        XCTAssertEqual(Self.countLiterals(in: ".font(.system(size: 12))"), 1)
        XCTAssertEqual(Self.countLiterals(in: ".opacity(0.12)"), 1)
        XCTAssertEqual(Self.countLiterals(in: "withAnimation(.easeOut(duration: 0.2))"), 1)
        XCTAssertEqual(Self.countLiterals(in: ".opacity(dark ? 0.22 : 0.16)"), 1)
        XCTAssertEqual(Self.countLiterals(in: "let url = \"https://x\"; view.padding(4)"), 1)

        XCTAssertEqual(Self.countLiterals(in: ".padding(Spacing.s)"), 0)
        XCTAssertEqual(Self.countLiterals(in: "VStack(spacing: 0) {"), 0)
        XCTAssertEqual(Self.countLiterals(in: ".opacity(isVisible ? 1 : 0)"), 0)
        XCTAssertEqual(Self.countLiterals(in: ".padding(.vertical, Spacing.xxs) // was .padding(4)"), 0)
    }
}
