import MenubucketCore
import SwiftUI

/// One chip: the share ring, the coloured core with the widget's symbol or
/// initial, and a red dot when its reading needs a look. The same drawing
/// as the folded stack in the menu bar (`MenuBarController.drawChip`).
struct ClusterChipFace: View {
    enum Emphasis { case rest, near, hovered, active }

    enum Metrics {
        static let face = MenuBarController.ChipMetrics.face
        static let ring = MenuBarController.ChipMetrics.ringWidth
        /// The share arc's diameter: around the disc, a gap away.
        static let arc = face + 2 * (MenuBarController.ChipMetrics.ringGap + ring / 2)
        static let badge = MenuBarController.ChipMetrics.badge
        static let glyph = MenuBarController.ChipMetrics.glyphSize
        static let nearScale: CGFloat = 1.03
        static let hoverScale: CGFloat = 1.08
        static let activeDisc: CGFloat = 26
    }

    let chip: ClusterChip
    let color: Color
    var emphasis: Emphasis = .rest
    /// The share arc around the disc, for the chip in focus. The folded
    /// stack in the menu bar never draws it.
    var showsRing = true

    var body: some View {
        ZStack {
            if emphasis == .active {
                // The open card's chip sits in a soft well, not a drawn ring.
                Circle()
                    .fill(Fill.pressed)
                    .frame(width: Metrics.activeDisc, height: Metrics.activeDisc)
            }
            // Only the chip in focus shows its share, so a fanned-out strip
            // is a row of clean discs rather than a row of gauges.
            if showsRing, emphasis == .hovered || emphasis == .active, let fraction = chip.fraction {
                Circle()
                    .stroke(Color.primary.opacity(MenuBarController.ChipMetrics.trackAlpha), lineWidth: Metrics.ring)
                    .frame(width: Metrics.arc, height: Metrics.arc)
                if fraction > 0 {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: Metrics.ring, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: Metrics.arc, height: Metrics.arc)
                }
            }
            Circle()
                .fill(color)
                .overlay(Circle().fill(LinearGradient(
                    colors: [.white.opacity(MenuBarController.ChipMetrics.sheenAlpha), .clear],
                    startPoint: .top, endPoint: .bottom
                )))
                .overlay(Circle().strokeBorder(
                    .white.opacity(MenuBarController.ChipMetrics.rimAlpha),
                    lineWidth: MenuBarController.ChipMetrics.rimWidth
                ))
                .frame(width: Metrics.face, height: Metrics.face)
            glyph
            if chip.alert {
                Circle()
                    .fill(Color.red)
                    .frame(width: Metrics.badge, height: Metrics.badge)
                    .offset(x: Metrics.face / 2 - Metrics.badge / 3, y: -(Metrics.face / 2 - Metrics.badge / 3))
            }
        }
        .opacity(chip.isStale ? MenuBarController.ChipMetrics.staleAlpha : 1)
        .scaleEffect(scale)
        .accessibilityElement()
        .accessibilityLabel(chip.spoken)
    }

    @ViewBuilder private var glyph: some View {
        if let symbol = chip.symbol {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: MenuBarController.ChipMetrics.glyphBox, height: MenuBarController.ChipMetrics.glyphBox)
        } else {
            Text(chip.initial)
                .font(.system(size: Metrics.glyph, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var ringColor: Color {
        chip.tint.map { Color(nsColor: MenuBarController.nsColor(for: $0)) } ?? .primary
    }

    private var scale: CGFloat {
        switch emphasis {
        case .rest: return 1
        case .near: return Metrics.nearScale
        case .hovered, .active: return Metrics.hoverScale
        }
    }
}

/// The glance under a chip the pointer rests on: the widget and its
/// reading. A click opens the card.
struct ClusterPeekView: View {
    let chip: ClusterChip
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ClusterChipFace(chip: chip, color: color, emphasis: .hovered)
            VStack(alignment: .leading, spacing: Spacing.hair / 2) {
                Text(chip.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !chip.reading.isEmpty {
                    Text(chip.reading)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(chip.tint.map { Color(nsColor: MenuBarController.nsColor(for: $0)) } ?? .primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, Spacing.xxs)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.stack)
        .fixedSize()
        .glassSurface(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(Spacing.s)
        .accessibilityHidden(true)
    }
}

/// The card a chip opens: the widget's own card, swapped in place as the
/// pointer slides to another chip, so the popover keeps one hosting view.
final class ClusterCardModel: ObservableObject {
    @Published var widget: LoadedWidget?
}

struct ClusterCardView: View {
    @ObservedObject var model: ClusterCardModel
    let runtime: WidgetRuntime

    var body: some View {
        if let widget = model.widget {
            MenuBarWidgetPopover(widget: widget, runtime: runtime)
                .id(widget.id)
        } else {
            Color.clear.frame(width: MenuBarWidgetPopover.width, height: ControlMetrics.height)
        }
    }
}
