import Foundation
import XCTest

/// BarShelf ships English and Korean. `scripts/sync-strings.sh --check` keeps
/// the catalog's keys in step with the source; these keep the Korean side
/// complete, so a new string cannot reach a Korean user in English, and a
/// translation cannot drop or reorder the values the code passes in.
final class StringCatalogTests: XCTestCase {
    private struct Entry {
        let key: String
        let korean: [String]
    }

    private func liveEntries() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization/Localizable.xcstrings")
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        return strings.compactMap { key, entry in
            // Stale keys are no longer used; `shouldTranslate: false` is a
            // deliberate "same in every language" (names, symbols).
            if entry["extractionState"] as? String == "stale" { return nil }
            if entry["shouldTranslate"] as? Bool == false { return nil }
            let ko = (entry["localizations"] as? [String: Any])?["ko"] as? [String: Any]
            return Entry(key: key, korean: ko.map(Self.translatedValues) ?? [])
        }
    }

    /// Every value a Korean localization can show: the single string, or each
    /// plural / device variation, translated ones only.
    private static func translatedValues(_ localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any] {
            guard unit["state"] as? String == "translated", let value = unit["value"] as? String else { return [] }
            return [value]
        }
        guard let variations = localization["variations"] as? [String: [String: Any]] else { return [] }
        return variations.values.flatMap { cases in
            cases.values.compactMap { ($0 as? [String: Any]).map(translatedValues) }.flatMap { $0 }
        }
    }

    func testEveryStringHasAKoreanTranslation() throws {
        let missing = try liveEntries().filter(\.korean.isEmpty).map(\.key).sorted()
        XCTAssertEqual(missing, [], "Add Korean for these in Localization/Localizable.xcstrings")
    }

    /// `%@`, `%lld` and friends are filled in order (or by position, `%1$@`);
    /// a translation with different ones shows garbage or crashes.
    func testKoreanKeepsTheFormatSpecifiers() throws {
        var mismatched: [String] = []
        for entry in try liveEntries() {
            let expected = Self.specifiers(in: entry.key)
            for value in entry.korean where Self.specifiers(in: value) != expected {
                mismatched.append("\(entry.key) → \(value)")
            }
        }
        XCTAssertEqual(mismatched, [])
    }

    /// The specifiers as a multiset of (position, type), so `%1$@ %2$@`
    /// matches `%2$@ %1$@` but `%@` does not match `%lld`.
    static func specifiers(in text: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSaAp%])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var next = 0
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let type = ns.substring(with: match.range(at: 3))
            if type == "%" { return nil }
            let length = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let position: Int
            if match.range(at: 1).location != NSNotFound {
                position = Int(ns.substring(with: match.range(at: 1))) ?? 0
            } else {
                next += 1
                position = next
            }
            return "\(position):\(length)\(type)"
        }.sorted()
    }

    func testSpecifierParsing() {
        XCTAssertEqual(Self.specifiers(in: "%lld widgets on %@"), ["1:lld", "2:@"])
        XCTAssertEqual(Self.specifiers(in: "%2$@에 %1$lld개"), ["1:lld", "2:@"])
        XCTAssertEqual(Self.specifiers(in: "100%% done"), [])
        XCTAssertNotEqual(Self.specifiers(in: "%@"), Self.specifiers(in: "%lld"))
    }
}
