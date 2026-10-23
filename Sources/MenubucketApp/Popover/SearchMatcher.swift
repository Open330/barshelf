import Foundation

/// How shelf search matches what was typed, the same way the gallery does:
/// every word must appear somewhere, in any order, ignoring case, accents and
/// full-/half-width forms. "cpu temp" finds "Temperature · CPU"; "cafe"
/// finds "Café"; "ｂａｔｔｅｒｙ" typed with a CJK input method finds "Battery".
struct SearchMatcher {
    let terms: [String]

    init(_ query: String) {
        terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Whether every term appears in at least one of `texts` — so a widget
    /// found by its name in one language and its other name in another
    /// counts once, and "날씨 seoul" can match a name and a reading together.
    func matches(_ texts: String?...) -> Bool {
        let present = texts.compactMap { $0 }
        guard !terms.isEmpty, !present.isEmpty else { return false }
        return terms.allSatisfy { term in
            present.contains { $0.range(of: term, options: Self.options) != nil }
        }
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
}
