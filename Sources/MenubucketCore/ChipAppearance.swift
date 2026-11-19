import Foundation

/// How the menu bar cluster's chips look: what a disc is made of, how strong
/// its colour is, which glyphs it carries and how large, and how closely the
/// folded chips sit.
public struct ChipAppearance: Codable, Equatable, Sendable {
    /// What a disc is made of.
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// A disc filled with the widget's colour, a white glyph on it.
        case solid
        /// A faint wash of the widget's colour, the glyph in that colour.
        case soft
        /// No colour: the bar's own text colour, like the items around it.
        case mono
    }

    /// How strong the colours are. Every chip takes the same lightness and
    /// strength, which is what makes a row of them a palette.
    public enum Tone: String, Codable, CaseIterable, Sendable {
        case vivid, balanced, muted
    }

    /// Which drawings stand for the readings.
    public enum GlyphSet: String, Codable, CaseIterable, Sendable {
        /// BarShelf's own plain filled glyphs where it has one, else the SF
        /// Symbol.
        case simple
        /// SF Symbols throughout.
        case symbols
    }

    public enum GlyphSize: String, Codable, CaseIterable, Sendable {
        case small, medium, large
    }

    /// How closely the folded chips sit.
    public enum Spacing: String, Codable, CaseIterable, Sendable {
        /// Side by side, every disc whole.
        case apart
        /// Overlapping, each chip over the one to its right.
        case stacked
    }

    public var style: Style
    public var tone: Tone
    public var glyphSet: GlyphSet
    public var glyphSize: GlyphSize
    public var spacing: Spacing

    public init(
        style: Style = .solid, tone: Tone = .balanced, glyphSet: GlyphSet = .simple,
        glyphSize: GlyphSize = .medium, spacing: Spacing = .apart
    ) {
        self.style = style
        self.tone = tone
        self.glyphSet = glyphSet
        self.glyphSize = glyphSize
        self.spacing = spacing
    }

    /// Lenient field by field: a missing value, or one a newer build wrote,
    /// costs that field only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ChipAppearance()
        style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? fallback.style
        tone = (try? container.decodeIfPresent(Tone.self, forKey: .tone)) ?? fallback.tone
        glyphSet = (try? container.decodeIfPresent(GlyphSet.self, forKey: .glyphSet)) ?? fallback.glyphSet
        glyphSize = (try? container.decodeIfPresent(GlyphSize.self, forKey: .glyphSize)) ?? fallback.glyphSize
        spacing = (try? container.decodeIfPresent(Spacing.self, forKey: .spacing)) ?? fallback.spacing
    }
}
