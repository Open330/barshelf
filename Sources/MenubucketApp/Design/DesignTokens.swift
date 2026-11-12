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
    /// A key cap: ⌘F, ↵.
    static let key: CGFloat = 4
    /// Widget cards, rows, banners — a separate object on the page. With the
    /// popup's 8 pt inset this sits concentric inside the popover's own corner.
    static let card: CGFloat = 16
    /// Large surfaces: sheets, overlays, the search panel, floating HUDs.
    static let surface: CGFloat = 22
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
    /// Content shown but no longer current: a reading past its refresh.
    static let staleOpacity: Double = 0.55
    /// A turned-off item, shown but stepped back.
    static let disabledOpacity: Double = 0.55
    /// A meter's or ring's empty track.
    static let track = adaptive(light: 0.09, dark: 0.14)
    /// Hairline borders, where a border is needed at all (Increase Contrast,
    /// floating chrome).
    static let hairline = adaptive(light: 0.10, dark: 0.14)

    /// Glass, where the system's own glass is not available (before macOS 26).
    /// Light from above: a sheen over the top third, and a rim that is
    /// brightest along the top and bottom edges.
    enum Glass {
        static let sheen = white(light: 0.60, dark: 0.075)
        static let rimHigh = white(light: 0.90, dark: 0.22)
        static let rimLow = white(light: 0.35, dark: 0.05)
        /// How far down the sheen fades out, as a fraction of the height.
        static let sheenDepth: CGFloat = 0.38
    }

    /// The highlight and edge of a coloured icon tile.
    enum Tile {
        static let sheen: Double = 0.28
        static let rim: Double = 0.18
    }

    /// The filled button that carries a screen's main action: the system
    /// accent with white text in light and dark alike, as macOS draws its
    /// own default button. (It was near-white on dark until 0.7.32.)
    static let primaryButton = Color(nsColor: .controlAccentColor)
    static let primaryButtonInk = Color(nsColor: .alternateSelectedControlTextColor)
    /// How much a filled button lightens under the pointer.
    static let hoverBrightness: Double = 0.05
    /// A control that cannot be used right now.
    static let disabled: Double = 0.4
    /// A key cap inside a filled button recedes behind the title.
    static let keyCapInButton: Double = 0.6

    /// How strongly a tint washes a surface: a `tinted` card, a status
    /// banner, a highlighted (just revealed) card.
    enum Wash {
        static let soft: Double = 0.10
        static let medium: Double = 0.14
        static let strong: Double = 0.18
    }

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.labelColor.withAlphaComponent(isDark(appearance) ? dark : light)
        })
    }

    private static func white(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: 1, alpha: isDark(appearance) ? dark : light)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Animation curves. Two, so the app moves one way.
enum Motion {
    /// Hover, press, show/hide of small controls.
    static let quick: Animation = .easeOut(duration: 0.15)
    /// Something changing place: reorder, page switch, a card resizing.
    static let arrange: Animation = .spring(response: 0.35, dampingFraction: 0.86)
    /// A control giving under a press: quick, with a little bounce back.
    static let press: Animation = .spring(response: 0.28, dampingFraction: 0.62)
    /// How far a pressed control gives.
    static let pressScale: CGFloat = 0.96

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

    /// Text at a size the widget chose, drawn at `size * scale`. Big text
    /// with a digit in it is a reading (23 %, 1:42, 18°) and is drawn as one
    /// (`metric`'s face); a big heading stays a heading. Whether it is big
    /// is decided by the authored size, so Compact density does not change
    /// the face. Code stays monospaced at any size.
    static func authored(size: CGFloat, scale: CGFloat = 1, role: String?, text: String = "0") -> Font {
        if role == "code" {
            return .system(size: size * scale, design: .monospaced)
        }
        if size >= heroThreshold, text.contains(where: \.isNumber) {
            return .system(size: size * scale, weight: .semibold, design: .rounded).monospacedDigit()
        }
        let weight: Font.Weight = role == "title" ? .bold : .regular
        return .system(size: size * scale, weight: weight)
    }

    /// The unit after a hero number (%, °): smaller, secondary, and raised to
    /// the cap height so the digits stay the reading.
    static func metricUnit(_ size: MetricSize = .regular) -> Font {
        .system(size: size.unitPoints, weight: .semibold, design: .rounded)
    }

    /// Hero digits are set a touch tight; at 34 pt the default tracking
    /// leaves them looking loose.
    static func metricTracking(_ size: MetricSize = .regular) -> CGFloat {
        -size.points * 0.025
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

        var unitPoints: CGFloat {
            switch self {
            case .compact: return 12
            case .regular: return 15
            }
        }

        /// How far the unit drops from the digits' top edge to meet their
        /// cap height.
        var unitRaise: CGFloat {
            switch self {
            case .compact: return 2
            case .regular: return 3
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

/// Small charts drawn inside a widget: `sparkline` and stacked meters.
enum ChartMetrics {
    /// A sparkline's height when the widget does not set one.
    static let sparklineHeight: CGFloat = 34
    static let lineWidth: CGFloat = 1.5
    /// The emphasised last point, and the soft halo around it.
    static let pointDiameter: CGFloat = 5
    static let haloDiameter: CGFloat = 9
    /// An untinted line is the primary ink, quieter than text.
    static let neutralInk: Double = 0.55
    /// The area under the line fades from this to `areaBottom`.
    static let areaTop: Double = 0.22
    static let areaBottom: Double = 0.02
    /// Parts of a stacked meter after the first, without their own tint,
    /// fade the meter's colour step by step so they stay distinguishable.
    static func segmentOpacity(_ index: Int) -> Double {
        max(1 - Double(index) * 0.3, 0.3)
    }
}

/// Fixed control metrics. Buttons are capsules, so only their height and
/// side inset are decisions.
enum ControlMetrics {
    static let height: CGFloat = 28
    static let smallHeight: CGFloat = 24
    static let inset: CGFloat = 13
    static let smallInset: CGFloat = 10
    static let keyCap: CGFloat = 16
    /// The ring around a chosen tile in a picker grid.
    static let selectionRing: CGFloat = 2
}

/// Shadows by how far something floats above the page.
enum Elevation {
    case none
    /// A filled button sitting on its surface.
    case control
    /// A HUD, toast or panel over other content: three soft layers, contact
    /// to ambient.
    case float
}

extension View {
    @ViewBuilder
    func elevation(_ level: Elevation) -> some View {
        switch level {
        case .none:
            self
        case .control:
            shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        case .float:
            shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.14), radius: 4, y: 3)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 14)
        }
    }
}
