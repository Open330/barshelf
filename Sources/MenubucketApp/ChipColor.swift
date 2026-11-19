import AppKit
import MenubucketCore

/// Chip colours as a palette: every face keeps its widget's hue and takes
/// one lightness and one strength (chroma) from the chosen tone, in OKLCH,
/// where equal numbers look equal. In HSB "the same brightness" left yellow
/// glaring beside a dull blue.
///
/// Pure arithmetic on sRGB components (0...1), after Björn Ottosson's OKLab
/// (https://bottosson.github.io/posts/oklab/).
enum ChipColor {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
    }

    struct LCH: Equatable {
        /// Lightness 0...1, chroma (0 is grey), hue in radians.
        var l: Double, c: Double, h: Double
    }

    /// A tone's face: lightness and chroma.
    static func face(_ tone: ChipAppearance.Tone) -> (l: Double, c: Double) {
        switch tone {
        case .vivid: return (0.64, 0.19)
        case .balanced: return (0.60, 0.13)
        case .muted: return (0.56, 0.075)
        }
    }

    /// Below this chroma a colour is grey: it has no hue to strengthen.
    static let greyChroma = 0.02
    /// The Soft style's glyph and words: light on a dark bar, deep on a
    /// light one.
    static let inkOnDark = 0.82
    static let inkOnLight = 0.42
    /// A second chip of a colour whose hue could not turn (orange, grey)
    /// is this much deeper per step, since the tone has levelled the
    /// brightness that told them apart.
    static let repeatStep = 0.07
    static let repeatFloor = 0.32
    /// Hues closer than this (radians) are one hue.
    static let sameHue = 0.14

    // MARK: - sRGB and OKLCH

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func oklch(_ rgb: RGB) -> LCH {
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return LCH(l: lightness, c: (a * a + bb * bb).squareRoot(), h: atan2(bb, a))
    }

    /// Linear sRGB, which is outside 0...1 for a colour sRGB cannot show.
    static func linearRGB(_ lch: LCH) -> RGB {
        let a = lch.c * cos(lch.h), b = lch.c * sin(lch.h)
        let l = pow(lch.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lch.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lch.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return RGB(
            r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    static func inGamut(_ lch: LCH, slack: Double = 0.0005) -> Bool {
        let rgb = linearRGB(lch)
        return [rgb.r, rgb.g, rgb.b].allSatisfy { $0 >= -slack && $0 <= 1 + slack }
    }

    static func srgb(_ lch: LCH) -> RGB {
        let rgb = linearRGB(lch)
        func channel(_ c: Double) -> Double { encoded(min(max(c, 0), 1)) }
        return RGB(r: channel(rgb.r), g: channel(rgb.g), b: channel(rgb.b))
    }

    /// `lch` with its chroma brought down until sRGB can show it; lightness
    /// and hue stay.
    static func fitted(_ lch: LCH) -> LCH {
        guard !inGamut(lch) else { return lch }
        var low = 0.0, high = lch.c
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if inGamut(LCH(l: lch.l, c: middle, h: lch.h)) { low = middle } else { high = middle }
        }
        return LCH(l: lch.l, c: low, h: lch.h)
    }

    /// `color`'s hue at lightness `l` and chroma `c`. A grey stays as grey
    /// as it was.
    static func retoned(_ color: LCH, l: Double, c: Double) -> LCH {
        fitted(LCH(l: l, c: color.c < greyChroma ? color.c : c, h: color.h))
    }

    /// Relative luminance (WCAG).
    static func luminance(_ rgb: RGB) -> Double {
        0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - NSColor

    static func rgb(_ color: NSColor) -> RGB? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGB(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent))
    }

    static func color(_ lch: LCH, alpha: CGFloat = 1) -> NSColor {
        let rgb = srgb(lch)
        return NSColor(srgbRed: CGFloat(rgb.r), green: CGFloat(rgb.g), blue: CGFloat(rgb.b), alpha: alpha)
    }

    /// The colour a disc is filled with: the widget's hue at the tone's
    /// lightness and chroma, `deeper` steps darker.
    static func face(_ color: NSColor, tone: ChipAppearance.Tone, deeper: Int = 0) -> NSColor {
        guard let rgb = rgb(color) else { return color }
        let target = face(tone)
        let l = deeper > 0 ? max(target.l - repeatStep * Double(deeper), repeatFloor) : target.l
        return self.color(retoned(oklch(rgb), l: l, c: target.c), alpha: color.alphaComponent)
    }

    /// The Soft style's glyph and words on a face: its hue, light on a dark
    /// bar and deep on a light one.
    static func ink(face: NSColor, tone: ChipAppearance.Tone, dark: Bool) -> NSColor {
        guard let rgb = rgb(face) else { return face }
        return color(retoned(oklch(rgb), l: dark ? inkOnDark : inkOnLight, c: self.face(tone).c))
    }

    /// Whether two colours have one hue, or none between them.
    static func sharesHue(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let first = rgb(a).map(oklch), let second = rgb(b).map(oklch) else { return false }
        if first.c < greyChroma || second.c < greyChroma { return first.c < greyChroma && second.c < greyChroma }
        let gap = abs(first.h - second.h)
        return min(gap, 2 * .pi - gap) < sameHue
    }
}
