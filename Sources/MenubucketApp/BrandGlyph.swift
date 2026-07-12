import SwiftUI

/// Vector brand marks for LLM providers, rendered from their official SVG
/// path data (simple-icons). Kept in-app and drawn as SwiftUI `Path`s so they
/// scale crisply, tint to the brand color, and need no bundled image files or
/// network — a `UINode` only references one by name via
/// `ImageSource(kind: "brand", name: "claude" | "codex")`.
enum BrandMark: String {
    case claude
    case codex

    /// Provider identifiers, as they appear in adapter payloads, mapped to a
    /// mark. `nil` → the caller falls back to a generic glyph.
    static func forProvider(_ provider: String) -> BrandMark? {
        switch provider.lowercased() {
        case "claude", "anthropic": return .claude
        case "codex", "openai": return .codex
        default: return nil
        }
    }

    /// simple-icons path data (24×24 viewBox).
    var pathData: String {
        switch self {
        case .claude: return Self.claudePath
        case .codex: return Self.codexPath
        }
    }

    /// The brand's own color when one reads well in both appearances (Claude's
    /// coral). Monochrome marks (OpenAI) return nil and adopt the foreground.
    var brandColor: Color? {
        switch self {
        case .claude: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: return nil
        }
    }

    private static let claudePath =
        "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    private static let codexPath =
        "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"
}

/// Renders a `BrandMark` scaled to fit `size`, tinted to the mark's brand
/// color (or `foreground` for monochrome marks).
struct BrandGlyphView: View {
    let mark: BrandMark
    let size: CGFloat
    /// Used when the mark has no intrinsic color (monochrome brands).
    var foreground: Color = .primary
    var accessibilityLabel: String?

    var body: some View {
        SVGPathShape(pathData: mark.pathData, viewBox: 24)
            .fill(mark.brandColor ?? foreground)
            .frame(width: size, height: size)
            .accessibilityLabel(accessibilityLabel ?? mark.rawValue.capitalized)
    }
}

/// A `Shape` built from an SVG path string in a square `viewBox`, scaled to
/// fill the shape's rect. Supports the full path command set (M/L/H/V/C/S/Q/T
/// and elliptical arcs A, absolute and relative), which covers the brand
/// marks' straight polygons (Claude) and arc/cubic outlines (OpenAI).
struct SVGPathShape: Shape {
    let pathData: String
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = SVGPathParser.parse(pathData)
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.midX - viewBox * scale / 2
        let dy = rect.midY - viewBox * scale / 2
        return unit.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
        )
    }
}

// MARK: - SVG path parser

/// Minimal SVG `d` attribute parser → `Path`. Handles absolute/relative
/// M L H V C S Q T A Z, comma/space/sign-delimited numbers, and elliptical
/// arcs (converted to cubic Béziers). Scoped to the brand-mark data this app
/// ships — not a general-purpose SVG engine.
enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = NumberScanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var previousControl: CGPoint?
        var previousCommand: Character = " "

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            let cmd = Character(command.uppercased())

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch cmd {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { break }
                current = point(x, y)
                path.move(to: current)
                subpathStart = current
                // Subsequent implicit coordinate pairs are treated as lineto.
                while let nx = scanner.number(), let ny = scanner.number() {
                    current = point(nx, ny)
                    path.addLine(to: current)
                }
                previousControl = nil
            case "L":
                while let x = scanner.number(), let y = scanner.number() {
                    current = point(x, y)
                    path.addLine(to: current)
                }
                previousControl = nil
            case "H":
                while let x = scanner.number() {
                    current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                    path.addLine(to: current)
                }
                previousControl = nil
            case "V":
                while let y = scanner.number() {
                    current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                    path.addLine(to: current)
                }
                previousControl = nil
            case "C":
                while let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    let c1 = point(x1, y1)
                    let c2 = point(x2, y2)
                    current = point(x, y)
                    path.addCurve(to: current, control1: c1, control2: c2)
                    previousControl = c2
                }
            case "S":
                while let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    let c1 = ("CS".contains(previousCommand.uppercased()))
                        ? CGPoint(x: 2 * current.x - (previousControl?.x ?? current.x),
                                  y: 2 * current.y - (previousControl?.y ?? current.y))
                        : current
                    let c2 = point(x2, y2)
                    current = point(x, y)
                    path.addCurve(to: current, control1: c1, control2: c2)
                    previousControl = c2
                }
            case "Q":
                while let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() {
                    let c = point(x1, y1)
                    current = point(x, y)
                    path.addQuadCurve(to: current, control: c)
                    previousControl = c
                }
            case "T":
                while let x = scanner.number(), let y = scanner.number() {
                    let c = ("QT".contains(previousCommand.uppercased()))
                        ? CGPoint(x: 2 * current.x - (previousControl?.x ?? current.x),
                                  y: 2 * current.y - (previousControl?.y ?? current.y))
                        : current
                    current = point(x, y)
                    path.addQuadCurve(to: current, control: c)
                    previousControl = c
                }
            case "A":
                while let rx = scanner.number(), let ry = scanner.number(),
                      let rot = scanner.number(), let large = scanner.flag(),
                      let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() {
                    let end = point(x, y)
                    addArc(
                        to: &path, from: current, to: end,
                        rx: rx, ry: ry, rotationDegrees: rot,
                        largeArc: large, sweep: sweep
                    )
                    current = end
                    previousControl = nil
                }
            case "Z":
                path.closeSubpath()
                current = subpathStart
                previousControl = nil
            default:
                break
            }
            previousCommand = command
        }
        return path
    }

    /// SVG elliptical arc → one or more cubic Béziers (endpoint → center
    /// parameterization, split at ≤90° segments). Standard W3C algorithm.
    private static func addArc(
        to path: inout Path, from start: CGPoint, to end: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        if start == end { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Scale radii up if they are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = sign * sqrt(max(0, num / den))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(max(dot / len, -1), 1))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                          (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segAngle = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(segAngle / 4)

        var angleStart = theta1
        for _ in 0..<segments {
            let angleEnd = angleStart + segAngle
            let cosA1 = cos(angleStart), sinA1 = sin(angleStart)
            let cosA2 = cos(angleEnd), sinA2 = sin(angleEnd)

            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(
                    x: cx + cosPhi * (rx * ex) - sinPhi * (ry * ey),
                    y: cy + sinPhi * (rx * ex) + cosPhi * (ry * ey)
                )
            }

            let end = map(cosA2, sinA2)
            // Control points from the unit-circle derivative, mapped to the ellipse.
            let d1 = map(cosA1 - t * sinA1, sinA1 + t * cosA1)
            let d2 = map(cosA2 + t * sinA2, sinA2 - t * cosA2)
            path.addCurve(to: end, control1: d1, control2: d2)
            angleStart = angleEnd
        }
    }
}

/// Scans SVG path numbers and command letters from a `d` string. SVG numbers
/// may run together with signs and decimals ("-.5157-4.9108" = two numbers),
/// so tokenizing is character-level rather than whitespace-split.
private struct NumberScanner {
    private let chars: [Character]
    private var index = 0

    init(_ string: String) { chars = Array(string) }

    private mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" {
                index += 1
            } else {
                break
            }
        }
    }

    /// Advances to and returns the next command letter, skipping any leading
    /// separators. Returns nil at end of input.
    mutating func nextCommand() -> Character? {
        skipSeparators()
        while index < chars.count {
            let c = chars[index]
            if c.isLetter {
                index += 1
                return c
            }
            // A number where a command is expected means "repeat previous
            // command"; callers loop on numbers, so this only happens at start.
            index += 1
        }
        return nil
    }

    /// Parses the next number, honoring SVG's sign/decimal boundaries.
    mutating func number() -> CGFloat? {
        skipSeparators()
        guard index < chars.count else { return nil }
        var start = index
        var seenDigit = false
        var seenDot = false

        if chars[index] == "+" || chars[index] == "-" { index += 1 }
        while index < chars.count {
            let c = chars[index]
            if c.isNumber {
                seenDigit = true
                index += 1
            } else if c == "." && !seenDot {
                seenDot = true
                index += 1
            } else if (c == "e" || c == "E"), seenDigit {
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                    index += 1
                }
            } else {
                break
            }
        }
        guard seenDigit else { index = start; return nil }
        let token = String(chars[start..<index])
        guard let value = Double(token) else { return nil }
        return CGFloat(value)
    }

    /// Arc flags are single-digit 0/1 that may abut the next number without a
    /// separator ("0 0 0-.5157" → flags 0,0,0 then -.5157).
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        if c == "0" { index += 1; return false }
        if c == "1" { index += 1; return true }
        return nil
    }
}
