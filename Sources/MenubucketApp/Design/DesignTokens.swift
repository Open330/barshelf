import SwiftUI

// BarShelf's own chrome — the hub, gallery, settings, and the popover frame
// around widgets — draws its spacing, corners, and status colours from here.
// Widget content keeps its own scale in `ViewTreeRenderer`: a widget is
// designed by its author, the window around it is not.
//
// Type comes from the system's semantic styles (`.headline`, `.callout`,
// `.caption`…), not point sizes, so it follows the user's text size setting.

/// Spacing steps. Anything between two of these is a rounding error, not a
/// design decision.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
}

/// Corner radii by role: what the shape is decides how round it is.
enum Radius {
    /// Buttons, chips, pills, small tiles.
    static let control: CGFloat = 6
    /// Cards, rows, banners — a separate object on the page.
    static let card: CGFloat = 10
    /// Large surfaces: sheets, overlays, the popover's inner panels.
    static let surface: CGFloat = 14
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
