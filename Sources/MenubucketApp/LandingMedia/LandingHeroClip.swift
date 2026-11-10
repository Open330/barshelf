import AppKit
import MenubucketCore
import SwiftUI

/// Clip 1 (the hero): the folded cluster in the menu bar; the pointer
/// sweeps across it, each chip growing into a pill with its reading and a
/// peek naming it; a click on System opens its card; → moves the card to
/// Sensors, then Keep Awake; esc closes it and the cluster folds again.
@MainActor
final class LandingHeroClip: LandingPlate {
    let demo: LandingDemo

    static let duration = 14.0
    /// Scene size in points (rendered to `LandingMediaMode.pixelSize`).
    static let size = CGSize(width: 864, height: 540)
    static let dark = true

    // Beats, in seconds.
    static let hover: [(t: Double, chip: Int)] = [(1.0, 0), (1.85, 1), (2.7, 2), (3.55, 3), (4.55, 0)]
    static let click = 5.35
    static let next1 = 7.9
    static let next2 = 10.0
    static let close = 12.0
    static let leave = 12.55
    static let zoomed: CGFloat = 1.75

    var size: CGSize { Self.size }
    /// Pixels per scene point; the film renders plates larger so its
    /// camera can move in without going soft.
    let scale: CGFloat

    private var wallpaper: LandingWallpaper!
    private var bar: LandingMenuBar!
    private var colors: [String: NSColor] = [:]
    private var cardIDs: [String] = []
    private var indexOf: [String: Int] = [:]
    private var events: [(t: Double, focus: Int?)] = []
    private var pointer: LandingPath!
    private var cards: [String: HostedView<AnyView>] = [:]

    init(demo: LandingDemo, scale: CGFloat? = nil) {
        self.demo = demo
        self.scale = scale ?? LandingMediaMode.pixelSize.width / Self.size.width
    }

    func prepare() -> Bool {
        guard let wallpaper = LandingWallpaper.make(size: Self.size, dark: Self.dark) else { return false }
        self.wallpaper = wallpaper
        let bar = LandingMenuBar(width: Self.size.width, dark: Self.dark)
        self.bar = bar
        demo.stage(at: 0)
        let chips = demo.clusterChips()
        colors = demo.chipColors(chips)
        cardIDs = [LandingDemo.ID.system, LandingDemo.ID.sensors, LandingDemo.ID.keepAwake]
        indexOf = Dictionary(uniqueKeysWithValues: chips.enumerated().map { ($1.widgetID, $0) })

        // Focus over time: the sweep, then the card's chip.
        events = []
        for beat in Self.hover { events.append((beat.t - 0.18, beat.chip)) }
        events.append((Self.next1, indexOf[cardIDs[1]]))
        events.append((Self.next2, indexOf[cardIDs[2]]))
        events.append((Self.leave + 0.25, nil))
        let cluster = LandingCluster(chips: chips, events: events)
        let itemRight = bar.itemRight

        // The pointer: in from below right, along the chips, back to System,
        // click, wait, and out to where it started.
        let start = CGPoint(x: itemRight + 70, y: 58)
        var keys: [(t: Double, point: CGPoint)] = [(0, start), (0.45, start)]
        for beat in Self.hover {
            keys.append((beat.t, cluster.chipPoint(beat.chip, focus: beat.chip, itemRight: itemRight)))
            keys.append((beat.t + 0.55, cluster.chipPoint(beat.chip, focus: beat.chip, itemRight: itemRight)))
        }
        keys.append((Self.leave - 0.05, keys.last!.point))
        keys.append((Self.leave + 0.7, start))
        pointer = LandingPath(keys: keys)

        // One hosted card per widget, captured every frame it is on screen.
        for id in cardIDs {
            guard let widget = demo.widget(id) else { return false }
            cards[id] = HostedView(AnyView(
                MenuBarWidgetPopover(widget: widget, runtime: demo.runtime, switchesWithArrows: true)
            ), dark: Self.dark)
        }
        return true
    }

    func frame(at t: Double) -> CGImage? {
        demo.stage(at: t)
        let itemRight = bar.itemRight
        // The readings tick: the pills show what the cards show.
        let cluster = LandingCluster(chips: demo.clusterChips(), events: events)
        let state = cluster.state(at: t)
        let zoom = Self.zoomed + (1 - Self.zoomed) * CGFloat(min(
            Ease.inOut(t, Self.click - 0.05, Self.click + 0.9),
            1 - Ease.inOut(t, Self.close + 0.2, Self.duration - 0.35)
        ))
        guard let clusterLayer = cluster.image(state, colors: colors, dark: Self.dark, scale: scale * zoom * 1.05)
        else { return nil }

        // The card on screen and its neighbours in time.
        let cardWindows: [(id: String, from: Double, to: Double)] = [
            (cardIDs[0], Self.click, Self.next1),
            (cardIDs[1], Self.next1, Self.next2),
            (cardIDs[2], Self.next2, Self.close),
        ]
        var shown: [(layer: LandingLayer, frame: CGRect, alpha: Double)] = []
        for window in cardWindows where t >= window.from - 0.001 && t < window.to + 0.14 {
            guard let host = cards[window.id], let layer = host.layer(scale: scale * 1.5) else { return nil }
            let fadeIn = Ease.out(t, window.from, window.from + 0.14)
            let fadeOut = 1 - Ease.out(t, window.to, window.to + 0.14)
            let chipIndex = indexOf[window.id] ?? 0
            let chipRect = cluster.chipRect(chipIndex, focus: chipIndex, itemRight: itemRight)
            var x = chipRect.midX - layer.size.width / 2
            x = min(max(x, 10), Self.size.width - layer.size.width - 10)
            let frame = CGRect(x: x, y: LandingMenuBar.height + 7, width: layer.size.width, height: layer.size.height)
            shown.append((layer, frame, min(fadeIn, fadeOut)))
        }

        // The peek: after a quarter second's rest on a chip, until it moves.
        var peek: (chip: ClusterChip, color: Color, center: CGFloat, alpha: Double)?
        for beat in Self.hover {
            let from = beat.t + 0.25, to = beat.t + 0.55
            let end = beat.chip == 0 && beat.t == Self.hover.last!.t ? Self.click : to + 0.04
            if t >= from && t < end + 0.1 {
                let chip = cluster.chips[beat.chip]
                let rect = cluster.chipRect(beat.chip, focus: beat.chip, itemRight: itemRight)
                peek = (chip, Color(nsColor: colors[chip.id] ?? .controlAccentColor), rect.midX,
                        min(Ease.out(t, from, from + 0.1), 1 - Ease.out(t, end, end + 0.08)))
            }
        }

        let press = Ease.window(t, Self.click - 0.08, Self.click + 0.1, rise: 0.06, fall: 0.1)
        let keyCaps: (keys: [String], alpha: Double)? = {
            for (time, keys) in [(Self.next1, ["→"]), (Self.next2, ["→"]), (Self.close, ["esc"])]
            where t >= time - 0.25 && t < time + 0.75 {
                return (keys, Ease.window(t, time - 0.25, time + 0.75, rise: 0.15, fall: 0.25))
            }
            return nil
        }()
        let scene = HeroScene(
            wallpaper: wallpaper, bar: bar, cluster: clusterLayer,
            clusterX: itemRight - MenuBarController.clusterItemInset - clusterLayer.size.width,
            cards: shown, peek: peek, pointer: pointer.at(t), press: press,
            keyCaps: keyCaps, zoom: zoom, anchor: CGPoint(x: Self.size.width - 6, y: 0)
        )
        return landingFrame(scene, size: Self.size, scale: scale)
    }

    func record(to dir: URL, ffmpeg: String) -> Bool {
        guard prepare() else { return false }
        guard let encoder = LandingEncoder(
            ffmpeg: ffmpeg, size: LandingMediaMode.pixelSize, fps: LandingMediaMode.fps,
            mp4: dir.appendingPathComponent("hero-menubar.mp4"),
            webm: dir.appendingPathComponent("hero-menubar.webm")
        ) else { return false }

        let frames = Int(Self.duration * Double(LandingMediaMode.fps))
        let posterTime = 7.2
        var poster: CGImage?
        for index in 0..<frames {
            let t = Double(index) / Double(LandingMediaMode.fps)
            guard let frame = frame(at: t) else { return false }
            encoder.append(frame)
            if abs(t - posterTime) < 0.5 / Double(LandingMediaMode.fps) { poster = frame }
        }
        guard encoder.finish() else { return false }
        guard let poster else { return true }
        var ok = LandingMediaMode.writeJPEG(poster, to: dir.appendingPathComponent("hero-menubar.jpg"))
        // The link preview (og:image): the same moment, cut to 1.91:1.
        let ogHeight = Int((CGFloat(poster.width) / 1.905).rounded())
        if let og = poster.cropping(to: CGRect(x: 0, y: 0, width: poster.width, height: ogHeight)) {
            ok = LandingMediaMode.writeJPEG(og, to: dir.appendingPathComponent("og-image.jpg")) && ok
        }
        return ok
    }
}

private struct HeroScene: View {
    let wallpaper: LandingWallpaper
    let bar: LandingMenuBar
    let cluster: LandingLayer
    let clusterX: CGFloat
    let cards: [(layer: LandingLayer, frame: CGRect, alpha: Double)]
    let peek: (chip: ClusterChip, color: Color, center: CGFloat, alpha: Double)?
    let pointer: CGPoint
    let press: Double
    let keyCaps: (keys: [String], alpha: Double)?
    let zoom: CGFloat
    let anchor: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                wallpaper.view
                bar.view
                cluster.view.offset(x: clusterX, y: 0)
                if let peek {
                    ClusterPeekGlass(wallpaper: wallpaper, chip: peek.chip, color: peek.color, center: peek.center)
                        .opacity(peek.alpha)
                }
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    ZStack(alignment: .topLeading) {
                        LandingGlass(wallpaper: wallpaper, frame: card.frame)
                        card.layer.view
                    }
                    .scaleEffect(0.97 + 0.03 * card.alpha, anchor: .top)
                    .opacity(card.alpha)
                    .offset(x: card.frame.minX, y: card.frame.minY)
                }
                LandingCursor(press: press).offset(x: pointer.x, y: pointer.y)
            }
            .frame(width: wallpaper.size.width, height: wallpaper.size.height, alignment: .topLeading)
            .scaleEffect(zoom, anchor: UnitPoint(x: anchor.x / wallpaper.size.width, y: anchor.y / wallpaper.size.height))
            if let keyCaps {
                LandingKeys(keys: keyCaps.keys, dark: wallpaper.dark)
                    .background(LandingGlassCapsule(dark: wallpaper.dark))
                    .opacity(keyCaps.alpha)
                    .scaleEffect(0.92 + 0.08 * keyCaps.alpha)
                    // In the open desktop left of the card.
                    .position(x: wallpaper.size.width * 0.32, y: wallpaper.size.height * 0.62)
            }
        }
        .frame(width: wallpaper.size.width, height: wallpaper.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, wallpaper.dark ? .dark : .light)
    }
}

/// The peek under a chip: the real `ClusterPeekView`, on redrawn glass.
struct ClusterPeekGlass: View {
    let wallpaper: LandingWallpaper
    let chip: ClusterChip
    let color: Color
    let center: CGFloat

    var body: some View {
        let peek = ClusterPeekView(chip: chip, color: color)
        let size = NSHostingView(rootView: peek).fittingSize
        let x = center - size.width / 2
        // The view carries `Spacing.s` of margin for its shadow.
        let card = CGRect(x: x + Spacing.s, y: LandingMenuBar.height + MenuBarClusterController.peekGap,
                          width: size.width - 2 * Spacing.s, height: size.height - 2 * Spacing.s)
        return ZStack(alignment: .topLeading) {
            LandingGlass(wallpaper: wallpaper, frame: card, radius: Radius.card)
                .offset(x: card.minX, y: card.minY)
            peek.offset(x: x, y: card.minY - Spacing.s)
        }
    }
}

struct LandingGlassCapsule: View {
    let dark: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill((dark ? Color.black : Color.white).opacity(dark ? 0.42 : 0.62))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(dark ? 0.18 : 0.8), lineWidth: 0.75))
            .elevation(.float)
    }
}
