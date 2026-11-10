import AppKit
import MenubucketCore
import SwiftUI

/// Clip 2 (the showcase): a click on the BarShelf icon opens the popup on
/// its Today page; a two-finger swipe moves to the System page; ⌘F opens
/// search and "cpu" is typed, its first result highlighted; esc closes
/// search and a second click closes the popup.
@MainActor
final class LandingPopupClip: LandingPlate {
    let demo: LandingDemo

    static let duration = 13.0
    static let size = CGSize(width: 864, height: 540)
    static let dark = false

    // Beats, in seconds.
    static let open = 1.3
    static let swipe = 3.2
    static let swipeRelease = 3.55
    static let swipeEnd = 4.1
    static let find = 5.6
    static let typed: [(t: Double, text: String)] = [(6.25, "c"), (6.5, "cp"), (6.75, "cpu")]
    static let findClose = 9.0
    static let close = 10.2

    var size: CGSize { Self.size }
    let scale: CGFloat
    /// Light or dark desktop; the landing clip is light.
    let dark: Bool

    private var wallpaper: LandingWallpaper!
    private var bar: LandingMenuBar!
    private var host: HostedView<AnyView>!
    private var search: HostedView<AnyView>!
    private var popupSize: CGSize = .zero
    private var popupFrame: CGRect = .zero
    private var itemRect: CGRect = .zero
    private var pointer: LandingPath!
    private var clusterLayer: LandingLayer?
    private var typedIndex = -1

    init(demo: LandingDemo, scale: CGFloat? = nil,
         dark: Bool? = nil) {
        self.demo = demo
        self.scale = scale ?? LandingMediaMode.pixelSize.width / Self.size.width
        self.dark = dark ?? Self.dark
    }

    func prepare() -> Bool {
        guard let wallpaper = LandingWallpaper.make(size: Self.size, dark: dark) else { return false }
        self.wallpaper = wallpaper
        let bar = LandingMenuBar(width: Self.size.width, dark: dark)
        self.bar = bar
        demo.stage(at: 0)
        let cluster = LandingCluster(chips: demo.clusterChips(), events: [])
        let colors = demo.chipColors(cluster.chips)
        let itemRight = bar.itemRight
        let mark = cluster.markPoint(itemRight: itemRight)
        let itemWidth = CGFloat(ClusterGeometry(count: cluster.chips.count).itemWidth) + 2 * MenuBarController.clusterItemInset
        itemRect = CGRect(x: itemRight - itemWidth, y: 2, width: itemWidth, height: LandingMenuBar.height - 4)

        let pager = demo.pager
        pager.index = 0
        demo.runtime.prefs.setGroupsOrder(["Today", "System"])
        host = HostedView(AnyView(RootView(runtime: demo.runtime, pager: pager)), dark: dark)
        // The search sheet is the real `SearchOverlay`, hosted on its own so
        // the redrawn glass can go between it and the shelf (offscreen
        // drawing leaves the system glass out).
        let searchWidth = RootView.defaultSize.width - 2 * Spacing.xs
        search = HostedView(AnyView(
            SearchOverlay(runtime: demo.runtime, pager: pager, isPresented: .constant(true))
                .frame(width: searchWidth)
        ), dark: dark)
        guard let first = host.layer(scale: scale * 1.25, settle: 0.6) else { return false }
        popupSize = first.size
        var popupX = itemRect.midX - popupSize.width / 2
        popupX = min(popupX, Self.size.width - popupSize.width - 8)
        popupFrame = CGRect(x: popupX, y: LandingMenuBar.height + 7, width: popupSize.width, height: popupSize.height)

        let start = CGPoint(x: itemRight + 40, y: 120)
        let inside = CGPoint(x: popupFrame.midX + 40, y: popupFrame.minY + 230)
        pointer = LandingPath(keys: [
            (0, start), (0.35, start), (Self.open - 0.12, mark), (Self.open + 0.35, mark),
            (Self.open + 1.0, inside), (Self.close - 0.75, inside), (Self.close - 0.1, mark),
            (Self.close + 0.3, mark), (Self.close + 1.3, start),
        ])
        clusterLayer = cluster.image(cluster.state(at: 0), colors: colors, dark: dark, scale: scale)
        typedIndex = -1
        return true
    }

    /// Times must not go backwards: the pager and the search field keep
    /// their state between frames, as they do on screen.
    func frame(at t: Double) -> CGImage? {
        demo.stage(at: t)
        let pager = demo.pager

        // Drive the real pager the way a two-finger swipe does.
        if t >= Self.swipe, t < Self.swipeEnd {
            if !pager.isSwiping, pager.index == 0 { pager.beginSwipe() }
            pager.updateSwipe(totalDeltaX: -swipeOffset(t, width: popupSize.width), pageCount: 2)
        } else if t >= Self.swipeEnd, pager.isSwiping {
            pager.index = 1
            pager.dragOffset = 0
            pager.cancelSwipe()
        }
        if let next = Self.typed.lastIndex(where: { $0.t <= t }), next > typedIndex {
            typedIndex = next
            type(Self.typed[next].text, in: search.hosting)
        }
        if t >= Self.close + 0.3, pager.index != 0 {
            // Closed: back to the first page and an empty search for the
            // next loop.
            type("", in: search.hosting)
            typedIndex = -1
            pager.index = 0
        }

        let popupAlpha = min(Ease.out(t, Self.open, Self.open + 0.12), 1 - Ease.out(t, Self.close, Self.close + 0.12))
        var shelf: LandingLayer?
        var sheet: (layer: LandingLayer, alpha: Double)?
        if popupAlpha > 0 {
            guard let layer = host.layer(scale: scale * 1.25) else { return nil }
            shelf = layer
            // The sheet springs in (`Motion.press`) and fades out.
            let sheetAlpha = min(Ease.spring(t, Self.find, duration: 0.3), 1 - Ease.out(t, Self.findClose, Self.findClose + 0.18))
            if t >= Self.find, t < Self.findClose + 0.18 {
                guard let layer = search.layer(scale: scale * 1.25) else { return nil }
                sheet = (layer, min(max(sheetAlpha, 0), 1))
            }
        }
        let press = max(
            Ease.window(t, Self.open - 0.08, Self.open + 0.1, rise: 0.06, fall: 0.1),
            Ease.window(t, Self.close - 0.08, Self.close + 0.1, rise: 0.06, fall: 0.1)
        )
        let keyCaps: (keys: [String], alpha: Double)? = {
            for (time, keys) in [(Self.find, ["⌘", "F"]), (Self.findClose, ["esc"])]
            where t >= time - 0.3 && t < time + 0.8 {
                return (keys, Ease.window(t, time - 0.3, time + 0.8, rise: 0.15, fall: 0.25))
            }
            return nil
        }()
        let highlight = t >= Self.open && t < Self.close ? 1.0 : 0
        let scene = PopupScene(
            wallpaper: wallpaper, bar: bar, cluster: clusterLayer,
            clusterX: bar.itemRight - MenuBarController.clusterItemInset - (clusterLayer?.size.width ?? 0),
            itemRect: itemRect, highlight: highlight, shelf: shelf, popupAlpha: popupAlpha, sheet: sheet,
            popupFrame: popupFrame,
            pointer: pointer.at(t), press: press, keyCaps: keyCaps
        )
        return landingFrame(scene, size: Self.size, scale: scale)
    }

    func record(to dir: URL, ffmpeg: String) -> Bool {
        guard prepare() else { return false }
        guard let encoder = LandingEncoder(
            ffmpeg: ffmpeg, size: LandingMediaMode.pixelSize, fps: LandingMediaMode.fps,
            mp4: dir.appendingPathComponent("popup-shelf.mp4"),
            webm: dir.appendingPathComponent("popup-shelf.webm")
        ) else { return false }
        var poster: CGImage?
        let posterTime = 7.6
        let frames = Int(Self.duration * Double(LandingMediaMode.fps))
        for index in 0..<frames {
            let t = Double(index) / Double(LandingMediaMode.fps)
            guard let frame = frame(at: t) else { return false }
            encoder.append(frame)
            if abs(t - posterTime) < 0.5 / Double(LandingMediaMode.fps) { poster = frame }
        }
        guard encoder.finish() else { return false }
        if let poster {
            return LandingMediaMode.writeJPEG(poster, to: dir.appendingPathComponent("popup-shelf.jpg"))
        }
        return true
    }

    /// How far the pages have moved: the fingers drag a third of the way,
    /// then the pager's spring (`Motion.arrange`) carries it home.
    private func swipeOffset(_ t: Double, width: CGFloat) -> CGFloat {
        let drag: CGFloat = width * 0.38
        if t < Self.swipeRelease {
            return drag * CGFloat(Ease.inOut(t, Self.swipe, Self.swipeRelease))
        }
        let x = t - Self.swipeRelease
        let omega = 2 * Double.pi / 0.35, zeta = 0.86
        let damped = omega * sqrt(1 - zeta * zeta)
        let spring = 1 - exp(-zeta * omega * x) * (cos(damped * x) + zeta * omega / damped * sin(damped * x))
        return drag + (width - drag) * CGFloat(spring)
    }

    /// Types into the search overlay's real field, as the keyboard would.
    private func type(_ text: String, in root: NSView) {
        guard let field = Self.searchField(in: root) else { return }
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func closeSearch(in root: NSView) {
        guard let field = Self.searchField(in: root), let delegate = field.delegate as? NSSearchFieldDelegate
        else { return }
        _ = delegate.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = searchField(in: sub) { return found }
        }
        return nil
    }
}

private struct PopupScene: View {
    let wallpaper: LandingWallpaper
    let bar: LandingMenuBar
    let cluster: LandingLayer?
    let clusterX: CGFloat
    let itemRect: CGRect
    let highlight: Double
    let shelf: LandingLayer?
    let popupAlpha: Double
    let sheet: (layer: LandingLayer, alpha: Double)?
    let popupFrame: CGRect
    let pointer: CGPoint
    let press: Double
    let keyCaps: (keys: [String], alpha: Double)?

    /// The sheet's place in scene points (for the glass behind it).
    private func sheetFrame(_ layer: LandingLayer) -> CGRect {
        CGRect(x: popupFrame.minX + Spacing.xs, y: popupFrame.minY + Spacing.xs,
               width: layer.size.width, height: layer.size.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper.view
            bar.view
            // The status item, highlighted while its popup is open.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.1 * highlight))
                .frame(width: itemRect.width, height: itemRect.height)
                .offset(x: itemRect.minX, y: itemRect.minY)
            if let cluster { cluster.view.offset(x: clusterX, y: 0) }
            if let shelf, popupAlpha > 0 {
                ZStack(alignment: .topLeading) {
                    shelf.view
                    if let sheet {
                        // RootView's scrim under the sheet.
                        Color.black.opacity(0.12 * sheet.alpha)
                        LandingGlass(wallpaper: wallpaper, frame: sheetFrame(sheet.layer), radius: Radius.surface)
                            .offset(x: Spacing.xs, y: Spacing.xs)
                            .opacity(sheet.alpha)
                        sheet.layer.view
                            .offset(x: Spacing.xs, y: Spacing.xs)
                            .opacity(sheet.alpha)
                    }
                }
                .frame(width: popupFrame.width, height: popupFrame.height, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .background(LandingGlass(wallpaper: wallpaper, frame: popupFrame), alignment: .topLeading)
                .opacity(popupAlpha)
                .offset(x: popupFrame.minX, y: popupFrame.minY)
            }
            LandingCursor(press: press).offset(x: pointer.x, y: pointer.y)
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
