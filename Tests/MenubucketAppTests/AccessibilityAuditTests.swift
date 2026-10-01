import XCTest

/// A control whose title is "" and whose label is hidden has no name at all:
/// VoiceOver announces "pop-up button" or "checkbox" and nothing else. With
/// `labelsHidden()` the title is invisible anyway, so the fix is always to
/// write the name there (or add an `accessibilityLabel`).
final class AccessibilityAuditTests: XCTestCase {
    func testEveryControlHasASpokenName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MenubucketApp")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let pattern = try NSRegularExpression(
            pattern: "\\b(Picker|Toggle|TextField|Stepper|Slider|SecureField|ColorPicker)\\(\"\"[,)]"
        )
        var unnamed: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard pattern.firstMatch(in: line, range: range) != nil else { continue }
                let following = lines[index..<min(lines.count, index + 25)].joined(separator: "\n")
                if !following.contains("accessibilityLabel") {
                    unnamed.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(unnamed, [], "controls without a name for VoiceOver")
    }
}
