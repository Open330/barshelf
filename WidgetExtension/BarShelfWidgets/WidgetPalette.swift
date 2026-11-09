import SwiftUI

/// BarShelf's color names, as widgets draw them. Mirrors `nodeColor` and
/// `WidgetAppearance.accentColor` in the app.
enum WidgetPalette {
    /// Status colours, as the app's `StatusTone` has them. The extension is
    /// its own target, so it keeps its own copy rather than importing the app.
    static let warning: Color = .orange
    static let critical: Color = .red

    static func color(_ name: String?, accent: Color = .accentColor) -> Color? {
        guard let raw = name?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .secondary.opacity(WidgetFill.tertiary)
        case "accent": return accent
        case "good", "green": return .green
        case "warning", "orange": return .orange
        case "danger", "red": return .red
        case "neutral", "gray", "grey": return .gray
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "default": return nil
        default:
            return hex(raw)
        }
    }

    private static func hex(_ value: String) -> Color? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

/// Spacing and corners, as the app's `DesignTokens` has them. The extension
/// is its own target, so it keeps its own copy; values a widget's tight
/// layout needs (the row indent, the gap between columns) are named here
/// rather than written where they are used.
enum WidgetSpacing {
    static let hair: CGFloat = 2
    static let xxs: CGFloat = 4
    static let stack: CGFloat = 6
    static let xs: CGFloat = 8
    /// Between a row's mark and its title.
    static let markGap: CGFloat = 7
    /// A row's second line, under its title: the mark's width and gap.
    static let rowIndent: CGFloat = 21
    /// Between columns of rings and rows.
    static let columnGap: CGFloat = 18
}

enum WidgetRadius {
    static let control: CGFloat = 6
}

/// Washes and type sizes the widget templates draw with.
enum WidgetFill {
    /// A ring's or bar's empty track.
    static let track: Double = 0.12
    /// A tile's quiet background.
    static let tile: Double = 0.08
    /// Tertiary text, from secondary.
    static let tertiary: Double = 0.6
}

enum WidgetTypeSize {
    /// The value inside a ring.
    static let ringValue: CGFloat = 11
    /// A tile's caption.
    static let tileCaption: CGFloat = 9
    /// A count badge.
    static let badge: CGFloat = 8
}

