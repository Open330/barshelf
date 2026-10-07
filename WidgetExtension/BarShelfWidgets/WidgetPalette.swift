import SwiftUI

/// BarShelf's color names, as widgets draw them. Mirrors `nodeColor` and
/// `WidgetAppearance.accentColor` in the app.
enum WidgetPalette {
    static func color(_ name: String?, accent: Color = .accentColor) -> Color? {
        guard let raw = name?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .secondary.opacity(0.6)
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
