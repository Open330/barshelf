import Foundation

/// User- and author-adjustable widget theming (R12).
///
/// Every field is optional: `nil` means "inherit". The effective appearance is
/// built by merging a user override over the manifest's author default over a
/// neutral baseline (see `WidgetPrefs.effectiveAppearance(for:)`). A neutral
/// `WidgetAppearance()` (all fields `nil`) must render exactly like the widget
/// did before theming existed.
///
/// Decoding is lenient: an invalid or wrong-typed field decodes to `nil`
/// rather than failing the whole manifest (or prefs) parse.
public struct WidgetAppearance: Codable, Equatable, Sendable {
    public enum Density: String, Codable, Sendable { case compact, regular }
    public enum CardStyle: String, Codable, Sendable { case plain, tinted }

    /// SF color name ("blue"…"pink") or a "#RRGGBB" hex string. `nil` → system accent.
    public var accent: String?
    /// `nil` → `.regular`.
    public var density: Density?
    /// `nil` → `.plain`.
    public var cardStyle: CardStyle?
    /// `nil` → `true`.
    public var showHeader: Bool?

    public init(
        accent: String? = nil,
        density: Density? = nil,
        cardStyle: CardStyle? = nil,
        showHeader: Bool? = nil
    ) {
        self.accent = accent
        self.density = density
        self.cardStyle = cardStyle
        self.showHeader = showHeader
    }

    /// Field-wise merge where `self` wins: each of `self`'s non-nil fields
    /// overrides `base`; nil fields fall through to `base`.
    public func merged(over base: WidgetAppearance) -> WidgetAppearance {
        WidgetAppearance(
            accent: accent ?? base.accent,
            density: density ?? base.density,
            cardStyle: cardStyle ?? base.cardStyle,
            showHeader: showHeader ?? base.showHeader
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accent, density, cardStyle, showHeader
    }

    /// Lenient decode: a missing, null, wrong-typed, or unknown-enum field
    /// becomes `nil`; a non-object payload yields an all-nil appearance. This
    /// never throws, so a malformed `appearance` block cannot fail a decode.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        let accent = (try? container.decodeIfPresent(String.self, forKey: .accent)) ?? nil
        let density = (try? container.decodeIfPresent(Density.self, forKey: .density)) ?? nil
        let cardStyle = (try? container.decodeIfPresent(CardStyle.self, forKey: .cardStyle)) ?? nil
        let showHeader = (try? container.decodeIfPresent(Bool.self, forKey: .showHeader)) ?? nil
        self.init(accent: accent, density: density, cardStyle: cardStyle, showHeader: showHeader)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accent, forKey: .accent)
        try container.encodeIfPresent(density, forKey: .density)
        try container.encodeIfPresent(cardStyle, forKey: .cardStyle)
        try container.encodeIfPresent(showHeader, forKey: .showHeader)
    }
}
