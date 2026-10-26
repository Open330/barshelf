import AppKit
import SwiftUI

// BarShelf's design system. Every surface the app draws — the popup and the
// widget cards in it, the hub, gallery, settings, the Dock — takes its
// spacing, corners, fills, motion and type from here, so one card looks the
// same wherever it appears. `DesignTokenLintTests` keeps new literals out.
//
// The direction: glass for chrome (the system popover and window materials),
// one quiet solid fill for content cards, the system accent, and numbers as
// the hero of a card — big, rounded, monospaced digits.
//
// Type comes from the system's semantic styles (`.headline`, `.callout`,
// `.caption`…), not point sizes, so it follows the user's text size setting.
// The one exception is `Typography.metric`, the hero number.

/// Spacing steps on a 4 pt grid. Anything between two of these is a rounding
/// error, not a design decision.
enum Spacing {
    /// Hairline gaps: between an icon and its badge, a pill's vertical inset.
    static let hair: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32

    /// Inside a widget card.
    static let cardInset: CGFloat = s
    /// Between cards, and between the cards and the popup's edge.
    static let cardGap: CGFloat = xs
    /// Between the rows of a stack inside a card.
    static let stack: CGFloat = 6
}

/// Corner radii by role: what the shape is decides how round it is. Nested
/// shapes are concentric — an inner radius is the outer one minus the inset
/// between them — so corners line up instead of pinching.
enum Radius {
    /// Buttons, fields, small tiles.
    static let control: CGFloat = 6
    /// Widget cards, rows, banners — a separate object on the page.
    static let card: CGFloat = 12
    /// Large surfaces: sheets, overlays, the search panel.
    static let surface: CGFloat = 16
    /// A shape nested `inset` points inside one of radius `outer`.
    static func nested(in outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 2)
    }
}

/// Fills by state. Neutral, not tinted: colour is for status and the accent.
/// Each adapts to light and dark, so callers never branch on colour scheme.
enum Fill {
    /// A card at rest.
    static let card = adaptive(light: 0.045, dark: 0.07)
    /// A card or row under the pointer, or being edited.
    static let hover = adaptive(light: 0.075, dark: 0.11)
    /// Pressed, or a selected row.
    static let pressed = adaptive(light: 0.11, dark: 0.15)
    /// A meter's or ring's empty track.
    static let track = adaptive(light: 0.09, dark: 0.14)
    /// Hairline borders, where a border is needed at all (Increase Contrast,
    /// floating chrome).
    static let hairline = adaptive(light: 0.10, dark: 0.14)

    /// How strongly a tint washes a surface: a `tinted` card, a status
    /// banner, a highlighted (just revealed) card.
    enum Wash {
        static let soft: Double = 0.10
        static let medium: Double = 0.14
        static let strong: Double = 0.18
    }

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.labelColor.withAlphaComponent(isDark ? dark : light)
        })
    }
}

/// Animation curves. Two, so the app moves one way.
enum Motion {
    /// Hover, press, show/hide of small controls.
    static let quick: Animation = .easeOut(duration: 0.15)
    /// Something changing place: reorder, page switch, a card resizing.
    static let arrange: Animation = .spring(response: 0.35, dampingFraction: 0.86)

    /// `animation` unless Reduce Motion is on, where a change just happens.
    static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Type the semantic styles cannot express.
enum Typography {
    /// A card's hero reading: CPU 23 %, 1:42 left, 82 % battery.
    static func metric(_ size: MetricSize = .regular) -> Font {
        .system(size: size.points, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// Text roles inside a widget. Fixed sizes rather than semantic styles:
    /// a widget is laid out by its author for these exact metrics, and the
    /// Compact density scales them all by the same step.
    enum WidgetRole {
        case title, body, caption, code, sectionTitle
    }

    static func widget(_ role: WidgetRole, compact: Bool = false) -> Font {
        let scale: CGFloat = compact ? compactScale : 1
        switch role {
        case .title: return .system(size: 13 * scale, weight: .semibold)
        case .body: return .system(size: 12 * scale)
        case .caption: return .caption
        case .code: return .system(size: 11 * scale, design: .monospaced)
        case .sectionTitle: return .system(size: 11 * scale, weight: .semibold)
        }
    }

    /// Compact density draws a widget about 15 % smaller.
    static let compactScale: CGFloat = 0.85

    /// From this size up, text a widget sizes itself is a reading.
    static let heroThreshold: CGFloat = 20

    /// Text at a size the widget chose. Big text is a reading and is drawn as
    /// one (`metric`'s face at that size); smaller text keeps its role's face.
    static func authored(size: CGFloat, role: String?) -> Font {
        if size >= heroThreshold {
            return .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
        }
        let weight: Font.Weight = role == "title" ? .bold : .regular
        let design: Font.Design = role == "code" ? .monospaced : .default
        return .system(size: size, weight: weight, design: design)
    }

    enum MetricSize {
        /// Two half-width cards side by side.
        case compact
        /// A full-width card.
        case regular

        var points: CGFloat {
            switch self {
            case .compact: return 26
            case .regular: return 34
            }
        }
    }
}

/// Severity of something the user should notice. Semantic, so it never
/// doubles as an accent colour, and every tone carries a symbol as well so
/// colour is not the only signal.
enum StatusTone {
    case info, success, warning, critical

    var color: Color {
        switch self {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}
