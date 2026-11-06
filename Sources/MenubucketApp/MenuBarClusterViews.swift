import MenubucketCore
import SwiftUI

/// What the fanned-out strip draws. The controller owns it; the views only
/// read it.
final class ClusterStripModel: ObservableObject {
    @Published var chips: [ClusterChip] = []
    /// The chip that stays put while the strip opens around it.
    @Published var anchor = 0
    @Published var expanded = false
    /// Where stack x = 0 sits in the strip's own coordinates.
    @Published var originX: CGFloat = 0
    /// Extra offset of the whole fan, to keep it on screen.
    @Published var fanShift: CGFloat = 0
    @Published var hovered: Int?
    @Published var markHovered = false
    /// The chip whose card is open.
    @Published var active: Int?
    var colors: [String: Color] = [:]

    var geometry: ClusterGeometry { ClusterGeometry(count: chips.count) }

    /// A chip's left edge in strip coordinates.
    func chipX(_ index: Int) -> CGFloat {
        let g = geometry
        return originX + (expanded
            ? CGFloat(g.expandedX(index, anchor: anchor)) + fanShift
            : CGFloat(g.collapsedX(index)))
    }

    var markX: CGFloat {
        let g = geometry
        return originX + (expanded
            ? CGFloat(g.expandedMarkX(anchor: anchor)) + fanShift
            : CGFloat(g.collapsedMarkX))
    }
}

/// The strip that replaces the folded stack under the pointer: a glass pill
/// with the chips side by side and the BarShelf icon at the end.
struct ClusterStripView: View {
    @ObservedObject var model: ClusterStripModel
    let mark: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let slot = CGFloat(ClusterGeometry.slot)
            ZStack(alignment: .topLeading) {
                pill(height: height)
                ForEach(Array(model.chips.enumerated()), id: \.element.id) { index, chip in
                    ClusterChipFace(
                        chip: chip,
                        color: model.colors[chip.widgetID] ?? .accentColor,
                        emphasis: emphasis(index)
                    )
                    .frame(width: slot, height: height)
                    .offset(x: model.chipX(index))
                }
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .foregroundStyle(model.markHovered ? .primary : .secondary)
                    .frame(width: CGFloat(ClusterGeometry.markWidth), height: height)
                    .background(
                        Circle().fill(model.markHovered ? Fill.hover : .clear)
                            .frame(width: ClusterChipFace.Metrics.hit, height: ClusterChipFace.Metrics.hit)
                    )
                    .offset(x: model.markX)
            }
            .animation(Motion.respecting(reduceMotion, Motion.arrange), value: model.expanded)
            .animation(Motion.respecting(reduceMotion, Motion.press), value: model.hovered)
            .animation(Motion.respecting(reduceMotion, Motion.press), value: model.active)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func pill(height: CGFloat) -> some View {
        let g = model.geometry
        let lead = model.chipX(0) - Spacing.xxs
        let trail = model.markX + CGFloat(ClusterGeometry.markWidth) + Spacing.xxs
        Capsule()
            .fill(.clear)
            .frame(width: max(trail - lead, 0), height: height - Spacing.hair)
            .glassSurface(Capsule(), elevation: .control)
            .offset(x: lead, y: Spacing.hair / 2)
            .opacity(model.expanded && g.count > 0 ? 1 : 0)
    }

    private func emphasis(_ index: Int) -> ClusterChipFace.Emphasis {
        if model.active == index { return .active }
        guard model.expanded, let hovered = model.hovered else { return .rest }
        if hovered == index { return .hovered }
        return abs(hovered - index) == 1 ? .near : .rest
    }
}

/// One chip: the share ring, the coloured core with the widget's symbol or
/// initial, and a red dot when its reading needs a look. The same drawing
/// as the folded stack in the menu bar (`MenuBarController.drawChip`).
struct ClusterChipFace: View {
    enum Emphasis { case rest, near, hovered, active }

    enum Metrics {
        static let face = MenuBarController.ChipMetrics.face
        static let core = MenuBarController.ChipMetrics.core
        static let ring = MenuBarController.ChipMetrics.ringWidth
        static let badge = MenuBarController.ChipMetrics.badge
        static let glyph = MenuBarController.ChipMetrics.glyphSize
        static let hit: CGFloat = 24
        static let nearScale: CGFloat = 1.04
        static let hoverScale: CGFloat = 1.12
        static let activeRing: CGFloat = 26
    }

    let chip: ClusterChip
    let color: Color
    var emphasis: Emphasis = .rest

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(MenuBarController.ChipMetrics.trackAlpha), lineWidth: Metrics.ring)
                .frame(width: Metrics.face - Metrics.ring, height: Metrics.face - Metrics.ring)
            if let fraction = chip.fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: Metrics.ring, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: Metrics.face - Metrics.ring, height: Metrics.face - Metrics.ring)
            }
            Circle()
                .fill(color.gradient)
                .overlay(Circle().fill(LinearGradient(
                    colors: [.white.opacity(MenuBarController.ChipMetrics.sheenAlpha), .clear],
                    startPoint: .top, endPoint: .center
                )))
                .frame(width: Metrics.core, height: Metrics.core)
            glyph
            if chip.alert {
                Circle()
                    .fill(Color.red)
                    .frame(width: Metrics.badge, height: Metrics.badge)
                    .offset(x: (Metrics.face - Metrics.badge) / 2, y: -(Metrics.face - Metrics.badge) / 2)
            }
            if emphasis == .active {
                Circle()
                    .strokeBorder(Color.primary.opacity(Fill.keyCapInButton), lineWidth: Metrics.ring)
                    .frame(width: Metrics.activeRing, height: Metrics.activeRing)
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
            ClusterChipFace(chip: chip, color: color)
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
