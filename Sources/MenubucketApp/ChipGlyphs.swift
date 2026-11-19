// Simple filled glyphs for the menu bar cluster's chips.
//
// cpu, lightning, thermometer-simple, fan, hard-drive, globe-simple,
// arrow-down, arrow-up and arrows-left-right are from Phosphor Icons, "fill"
// weight (https://phosphoricons.com), under the MIT License:
//
//   Copyright (c) 2023 Phosphor Icons
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to
//   the following conditions:
//
//   The above copyright notice and this permission notice shall be included
//   in all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//   CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// memory, battery and gpu were drawn for BarShelf.
// See docs/THIRD-PARTY-NOTICES.md.

import AppKit

/// The Simple glyph set: one plain filled shape per common reading, in
/// place of an SF Symbol whose fine detail turns to noise in an 18 pt disc.
enum ChipGlyph: String, CaseIterable, Sendable {
    case cpu = "cpu"
    case memory = "memory"
    case lightning = "lightning"
    case thermometerSimple = "thermometer-simple"
    case battery = "battery"
    case fan = "fan"
    case hardDrive = "hard-drive"
    case globeSimple = "globe-simple"
    case arrowDown = "arrow-down"
    case arrowUp = "arrow-up"
    case gpu = "gpu"
    case arrowsLeftRight = "arrows-left-right"

    /// The glyph that stands for an SF Symbol (what `ClusterChip.symbol`
    /// holds); nil when the set has none and the symbol itself is drawn.
    static func replacing(_ symbol: String) -> ChipGlyph? {
        // Only the plain arrows: an arrow in a circle or a square is its
        // own drawing.
        switch symbol {
        case "arrow.down", "arrow.down.to.line": return .arrowDown
        case "arrow.up", "arrow.up.to.line": return .arrowUp
        default: break
        }
        return prefixes.first { symbol.hasPrefix($0.prefix) }?.glyph
    }

    private static let prefixes: [(prefix: String, glyph: ChipGlyph)] = [
        ("cpu", .cpu),
        ("memorychip", .memory),
        ("bolt", .lightning),
        ("thermometer", .thermometerSimple),
        ("battery", .battery),
        ("fan", .fan),
        ("internaldrive", .hardDrive),
        ("externaldrive", .hardDrive),
        ("network", .globeSimple),
        ("globe", .globeSimple),
        ("square.grid.3x3", .gpu),
        ("arrow.left.arrow.right", .arrowsLeftRight),
    ]

    /// The glyph as a vector image, black on clear; nil if it cannot be
    /// read, and the SF Symbol is drawn instead.
    func image() -> NSImage? {
        guard let image = NSImage(data: Data(svg.utf8)), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    var svg: String {
        let rule = usesEvenOdd ? " fill-rule=\"evenodd\"" : ""
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\">"
            + "<path fill=\"#000\"\(rule) d=\"\(path)\"/></svg>"
    }

    private var usesEvenOdd: Bool {
        switch self {
        case .memory, .battery, .gpu: return true
        default: return false
        }
    }

    /// The path, in a 256 by 256 box.
    private var path: String {
        switch self {
        case .cpu:
            return "M104,104h48v48H104Zm136,48a8,8,0,0,1-8,8H216v40a16,16,0,0,1-16,16H160v16a8,8,0,0,1-16,0V216H112v16a8,8,0,0,1-16,0V216H56a16,16,0,0,1-16-16V160H24a8,8,0,0,1,0-16H40V112H24a8,8,0,0,1,0-16H40V56A16,16,0,0,1,56,40H96V24a8,8,0,0,1,16,0V40h32V24a8,8,0,0,1,16,0V40h40a16,16,0,0,1,16,16V96h16a8,8,0,0,1,0,16H216v32h16A8,8,0,0,1,240,152ZM168,96a8,8,0,0,0-8-8H96a8,8,0,0,0-8,8v64a8,8,0,0,0,8,8h64a8,8,0,0,0,8-8Z"
        case .memory:
            return "M40,64h176a16,16 0 0 1 16,16v60a16,16 0 0 1 -16,16h-176a16,16 0 0 1 -16,-16v-60a16,16 0 0 1 16,-16ZM44,156h26v32a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8ZM92,156h26v32a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8ZM138,156h26v32a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8ZM186,156h26v32a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8Z"
        case .lightning:
            return "M213.85,125.46l-112,120a8,8,0,0,1-13.69-7l14.66-73.33L45.19,143.49a8,8,0,0,1-3-13l112-120a8,8,0,0,1,13.69,7L153.18,90.9l57.63,21.61a8,8,0,0,1,3,12.95Z"
        case .thermometerSimple:
            return "M160,146.08V40a32,32,0,0,0-64,0V146.08a56,56,0,1,0,64,0ZM128,24a16,16,0,0,1,16,16v64H112V40A16,16,0,0,1,128,24Z"
        case .battery:
            return "M40,80h148a24,24 0 0 1 24,24v48a24,24 0 0 1 -24,24h-148a24,24 0 0 1 -24,-24v-48a24,24 0 0 1 24,-24ZM232,104h4a8,8 0 0 1 8,8v32a8,8 0 0 1 -8,8h-4a8,8 0 0 1 -8,-8v-32a8,8 0 0 1 8,-8Z"
        case .fan:
            return "M233,135a60,60,0,0,0-89.62-35.45l16.39-65.44a8,8,0,0,0-3.45-8.68A60,60,0,1,0,95.69,128.91L30.82,147.44a8,8,0,0,0-5.8,7.32,60,60,0,0,0,44.42,60.66,60.52,60.52,0,0,0,15.62,2.07,60.07,60.07,0,0,0,59.88-62l48.48,46.92a8,8,0,0,0,9.25,1.35A60,60,0,0,0,233,135ZM130.44,147.85a20,20,0,1,1,17.41-22.29A20,20,0,0,1,130.44,147.85Z"
        case .hardDrive:
            return "M224,64H32A16,16,0,0,0,16,80v96a16,16,0,0,0,16,16H224a16,16,0,0,0,16-16V80A16,16,0,0,0,224,64Zm-36,76a12,12,0,1,1,12-12A12,12,0,0,1,188,140Z"
        case .globeSimple:
            return "M128,24h0A104,104,0,1,0,232,128,104.12,104.12,0,0,0,128,24Zm87.62,96H175.79C174,83.49,159.94,57.67,148.41,42.4A88.19,88.19,0,0,1,215.63,120ZM96.23,136h63.54c-2.31,41.61-22.23,67.11-31.77,77C118.45,203.1,98.54,177.6,96.23,136Zm0-16C98.54,78.39,118.46,52.89,128,43c9.55,9.93,29.46,35.43,31.77,77Zm52.18,93.6c11.53-15.27,25.56-41.09,27.38-77.6h39.84A88.19,88.19,0,0,1,148.41,213.6Z"
        case .arrowDown:
            return "M205.66,149.66l-72,72a8,8,0,0,1-11.32,0l-72-72A8,8,0,0,1,56,136h64V40a8,8,0,0,1,16,0v96h64a8,8,0,0,1,5.66,13.66Z"
        case .arrowUp:
            return "M207.39,115.06A8,8,0,0,1,200,120H136v96a8,8,0,0,1-16,0V120H56a8,8,0,0,1-5.66-13.66l72-72a8,8,0,0,1,11.32,0l72,72A8,8,0,0,1,207.39,115.06Z"
        case .gpu:
            return "M36,56h184a16,16 0 0 1 16,16v72a16,16 0 0 1 -16,16h-184a16,16 0 0 1 -16,-16v-72a16,16 0 0 1 16,-16ZM66,108a30,30 0 1 0 60,0a30,30 0 1 0 -60,0ZM150,160h26v28a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8ZM190,160h26v28a8,8 0 0 1 -8,8h-10a8,8 0 0 1 -8,-8ZM48,160h60v28a8,8 0 0 1 -8,8h-44a8,8 0 0 1 -8,-8Z"
        case .arrowsLeftRight:
            return "M42.34,85.66a8,8,0,0,1,0-11.32l32-32A8,8,0,0,1,88,48V72H208a8,8,0,0,1,0,16H88v24a8,8,0,0,1-13.66,5.66Zm171.32,84.68-32-32A8,8,0,0,0,168,144v24H48a8,8,0,0,0,0,16H168v24a8,8,0,0,0,13.66,5.66l32-32A8,8,0,0,0,213.66,170.34Z"
        }
    }
}
