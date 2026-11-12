#if DEBUG
import AppKit
import CoreImage
import MenubucketCore
import SwiftUI
@testable import MenubucketApp

/// `barshelf-app landing-media <dir> [hero] [popup] [stills] [film]` records the
/// landing page's videos and stills (site/shots) from the real app views.
///
/// Regenerate every release (see docs/RELEASING.md, "Landing page media"):
///
///     swift build
///     scripts/render-landing-media.sh            # all of it, into site/shots
///     scripts/render-landing-media.sh hero       # one clip
///
/// What is real and what is staged:
/// - Real: every card, popup and chip — `MenuBarWidgetPopover`, `RootView`
///   with its search overlay, `WidgetCardView`, the cluster as
///   `MenuBarController.clusterImage` draws it, `ClusterPeekView` — rendered
///   offscreen through `NSHostingView`, fed by BarShelf's own bundled
///   widgets, whose workflows the real engine evaluates (`LandingDemo`).
/// - Staged: the source data (made-up readings, never this Mac's), the
///   desktop (a generated wallpaper and a menu bar of neutral system
///   items), the pointer, the key caps, and the glass: offscreen drawing
///   has no vibrancy, so the material is redrawn as the wallpaper behind the
///   surface, blurred and tinted, with a rim and the `Elevation.float`
///   shadow.
///
/// Frames are a pure function of time and each clip ends where it starts,
/// so the videos loop cleanly. Encoded with ffmpeg (H.264 MP4 + VP9 WebM,
/// plus a JPEG poster each). The runtime writes state under the home
/// folder, so this refuses to run unless `CFFIXED_USER_HOME` points at a
/// scratch folder; the script sets one up.
enum LandingMediaMode {
    /// Output video size in pixels; scenes are laid out in points at
    /// `LandingStage.size` and rendered at `scale`.
    static let pixelSize = CGSize(width: 1440, height: 900)
    static let fps = 30

    @MainActor
    static func run(outputDir: String, only: Set<String>) -> Int32 {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data(
                "landing-media builds a widget runtime; set CFFIXED_USER_HOME to a scratch folder\n".utf8
            ))
            return 2
        }
        guard let ffmpeg = findFFmpeg() else {
            FileHandle.standardError.write(Data("landing-media needs ffmpeg (brew install ffmpeg)\n".utf8))
            return 2
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: home).appendingPathComponent("landing-app-prefs.json"))
        let runtime = WidgetRuntime(appPrefs: prefs)
        guard let demo = LandingDemo(runtime: runtime) else { return 1 }
        // Let the runtime's start-up work settle before anything is drawn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let all = only.isEmpty
        var ok = true
        if all || only.contains("hero") {
            ok = LandingHeroClip(demo: demo).record(to: dir, ffmpeg: ffmpeg) && ok
        }
        if all || only.contains("popup") {
            ok = LandingPopupClip(demo: demo).record(to: dir, ffmpeg: ffmpeg) && ok
        }
        if all || only.contains("stills") {
            ok = LandingStills(demo: demo).render(to: dir) && ok
        }
        // The film is asked for by name: film (the landing page's cut, as
        // film.*), film-keynote, film-trailer, or film-preview (a few
        // stills of each).
        if only.contains("film") {
            ok = LandingFilm(demo: demo, style: LandingFilm.landing).record(to: dir, ffmpeg: ffmpeg, name: "film") && ok
        }
        for style in LandingFilm.Style.allCases where only.contains("film-\(style.rawValue)") {
            ok = LandingFilm(demo: demo, style: style).record(to: dir, ffmpeg: ffmpeg) && ok
        }
        if only.contains("film-preview") {
            for style in LandingFilm.Style.allCases {
                let times = style == .keynote
                    ? [1.6, 3.4, 5.2, 6.7, 9.0, 13.0, 20.0, 28.5, 34.5, 39.5, 44.5]
                    : [0.9, 2.6, 6.0, 9.6, 15.0, 20.5, 25.0, 28.5, 32.5]
                ok = LandingFilm(demo: demo, style: style).record(to: dir, ffmpeg: ffmpeg, previewTimes: times) && ok
            }
        }
        return ok ? 0 : 1
    }

    static func findFFmpeg() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url) } catch { return false }
        print("wrote \(url.path)")
        return true
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.84) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return false }
        do { try data.write(to: url) } catch { return false }
        print("wrote \(url.path)")
        return true
    }
}

// MARK: - Plates

/// One recorded scene as a function of time: the landing clips and every
/// shot of the film draw from these. `frame(at:)` gives the scene at `t`
/// seconds, `size` points at `scale` pixels each. Some plates drive real
/// views that keep state between frames (a pager, a search field), so a
/// plate's times should not go backwards.
@MainActor
protocol LandingPlate: AnyObject {
    var size: CGSize { get }
    var scale: CGFloat { get }
    func prepare() -> Bool
    func frame(at t: Double) -> CGImage?
}

// MARK: - Encoding

/// Streams frames to ffmpeg as raw RGBA and writes an MP4 and a WebM.
final class LandingEncoder {
    private let process = Process()
    private let input = Pipe()
    private let size: CGSize
    private var buffer: [UInt8]
    private let context: CGContext
    let outputs: [URL]

    init?(ffmpeg: String, size: CGSize, fps: Int, mp4: URL, webm: URL?, crf: (mp4: Int, webm: Int) = (18, 36)) {
        self.size = size
        let width = Int(size.width), height = Int(size.height)
        buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
        var arguments = [
            "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:v", "libx264", "-preset", "slow", "-crf", "\(crf.mp4)", "-tune", "animation",
            "-movflags", "+faststart", mp4.path,
        ]
        var outputs = [mp4]
        if let webm {
            arguments += [
                "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "\(crf.webm)", "-row-mt", "1",
                "-deadline", "good", "-cpu-used", "2", webm.path,
            ]
            outputs.append(webm)
        }
        self.outputs = outputs
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
    }

    func append(_ image: CGImage) {
        let rect = CGRect(origin: .zero, size: size)
        context.clear(rect)
        context.draw(image, in: rect)
        guard let data = context.data else { return }
        input.fileHandleForWriting.write(Data(bytes: data, count: Int(size.width * size.height * 4)))
    }

    func finish() -> Bool {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        for url in outputs where process.terminationStatus == 0 { print("wrote \(url.path)") }
        return process.terminationStatus == 0
    }
}

// MARK: - Rasterizing

/// A real view hosted offscreen in an unshown window: `NSHostingView` draws
/// the native parts (scroll views, the search field, menus) that
/// `ImageRenderer` leaves blank. Kept alive across frames, so state changes
/// reach the same view graph the way they would on screen.
@MainActor
final class HostedView<Content: View> {
    let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    /// Every hosted view's clocks read `HostedView.now`: the demo's staged
    /// moment, not the time of rendering.
    static var now: Date? { LandingDemo.stagedNow }

    init(_ view: Content, dark: Bool) {
        hosting = NSHostingView(rootView: AnyView(view.environment(\.widgetPinnedNow, Self.now)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
    }

    /// The view as it stands, at `size` (nil: the size it asks for), after
    /// `settle` seconds of run loop for pending updates.
    func capture(size: CGSize? = nil, scale: CGFloat, settle: TimeInterval = 0.02) -> CGImage? {
        if settle > 0 { RunLoop.main.run(until: Date().addingTimeInterval(settle)) }
        hosting.layoutSubtreeIfNeeded()
        let fitted = size ?? hosting.fittingSize
        if hosting.frame.size != fitted {
            window.setContentSize(fitted)
            hosting.frame = NSRect(origin: .zero, size: fitted)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((fitted.width * scale).rounded()),
            pixelsHigh: Int((fitted.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = fitted
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }
}

/// A rasterized real view and its size in points.
struct LandingLayer {
    let image: CGImage
    let size: CGSize

    var view: some View {
        Image(decorative: image, scale: CGFloat(image.width) / size.width)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
    }
}

extension HostedView {
    func layer(size: CGSize? = nil, scale: CGFloat, settle: TimeInterval = 0.02) -> LandingLayer? {
        guard let image = capture(size: size, scale: scale, settle: settle) else { return nil }
        return LandingLayer(image: image, size: CGSize(width: CGFloat(image.width) / scale,
                                                        height: CGFloat(image.height) / scale))
    }
}

/// Renders one scene frame.
@MainActor
func landingFrame<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> CGImage? {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
        .environment(\.widgetStillRender, true))
    renderer.scale = scale
    renderer.isOpaque = true
    return renderer.cgImage
}

// MARK: - Timing

/// Shapes of motion. Everything in a clip is a function of time.
enum Ease {
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    /// 0 before `from`, 1 after `to`, smooth in between.
    static func inOut(_ t: Double, _ from: Double, _ to: Double) -> Double {
        let x = clamp((t - from) / (to - from))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func out(_ t: Double, _ from: Double, _ to: Double) -> Double {
        let x = clamp((t - from) / (to - from))
        return 1 - pow(1 - x, 3)
    }
    /// A soft spring settling at 1: a little overshoot, then rest.
    static func spring(_ t: Double, _ from: Double, duration: Double = 0.45) -> Double {
        let x = clamp((t - from) / duration)
        guard x < 1 else { return 1 }
        return 1 - exp(-6 * x) * cos(x * 2.6 * .pi) * (1 - x)
    }
    /// Up over `rise`, held, down over `fall`: 0…1…0.
    static func window(_ t: Double, _ start: Double, _ end: Double, rise: Double = 0.12, fall: Double = 0.12) -> Double {
        min(out(t, start, start + rise), 1 - out(t, end - fall, end))
    }
}

/// Points along a path over time, eased between keyframes.
struct LandingPath {
    let keys: [(t: Double, point: CGPoint)]

    func at(_ t: Double) -> CGPoint {
        guard let first = keys.first else { return .zero }
        guard t > first.t else { return first.point }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
            let e = Ease.inOut(t, a.t, b.t)
            // A slight arc, as a hand moves a pointer.
            let dx = b.point.x - a.point.x, dy = b.point.y - a.point.y
            let bow = sin(e * .pi) * min(hypot(dx, dy) * 0.06, 10)
            return CGPoint(x: a.point.x + dx * e, y: a.point.y + dy * e + bow)
        }
        return keys.last!.point
    }
}

// MARK: - Desktop

/// A generated wallpaper (no images of anyone else's), sharp and blurred
/// for the glass.
struct LandingWallpaper {
    let sharp: CGImage
    let blurred: CGImage
    let size: CGSize
    let dark: Bool

    @MainActor
    static func make(size: CGSize, dark: Bool) -> LandingWallpaper? {
        let scale: CGFloat = 2
        let renderer = ImageRenderer(content: LandingMesh(dark: dark).frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let sharp = renderer.cgImage else { return nil }
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 34 * scale])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: input.extent)
        guard let blurredImage = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
        return LandingWallpaper(sharp: sharp, blurred: blurredImage, size: size, dark: dark)
    }

    var view: some View {
        Image(decorative: sharp, scale: 2).resizable().frame(width: size.width, height: size.height)
    }
}

private struct LandingMesh: View {
    let dark: Bool

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    var body: some View {
        let colors: [Color] = dark ? [
            Self.rgb(0.05, 0.06, 0.15), Self.rgb(0.09, 0.08, 0.25), Self.rgb(0.16, 0.08, 0.27),
            Self.rgb(0.03, 0.19, 0.27), Self.rgb(0.17, 0.14, 0.42), Self.rgb(0.40, 0.13, 0.36),
            Self.rgb(0.02, 0.27, 0.30), Self.rgb(0.27, 0.19, 0.48), Self.rgb(0.80, 0.35, 0.28),
        ] : [
            Self.rgb(0.84, 0.89, 0.97), Self.rgb(0.80, 0.84, 0.98), Self.rgb(0.93, 0.85, 0.95),
            Self.rgb(0.66, 0.84, 0.91), Self.rgb(0.86, 0.79, 0.96), Self.rgb(0.98, 0.81, 0.80),
            Self.rgb(0.55, 0.79, 0.84), Self.rgb(0.76, 0.75, 0.97), Self.rgb(0.99, 0.74, 0.60),
        ]
        if #available(macOS 15.0, *) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.48], [0.42, 0.56], [1, 0.40],
                [0, 1], [0.62, 1], [1, 1],
            ], colors: colors, smoothsColors: true)
        } else {
            LinearGradient(colors: [colors[0], colors[4], colors[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The system material, redrawn: what lies behind `frame` blurred, a tint,
/// a sheen from above and a rim, floating with `Elevation.float`.
struct LandingGlass: View {
    let wallpaper: LandingWallpaper
    /// Where the surface sits, in scene points.
    let frame: CGRect
    var radius: CGFloat = 24
    var tint: Double? = nil

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        let dark = wallpaper.dark
        ZStack(alignment: .topLeading) {
            Image(decorative: wallpaper.blurred, scale: 2)
                .resizable()
                .frame(width: wallpaper.size.width, height: wallpaper.size.height)
                .offset(x: -frame.minX, y: -frame.minY)
            (dark ? Color.black : Color.white).opacity(tint ?? (dark ? 0.42 : 0.55))
            LinearGradient(colors: [.white.opacity(dark ? 0.07 : 0.35), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4))
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(dark ? 0.26 : 0.9), location: 0),
                .init(color: .white.opacity(dark ? 0.06 : 0.4), location: 0.3),
                .init(color: .white.opacity(dark ? 0.06 : 0.4), location: 0.8),
                .init(color: .white.opacity(dark ? 0.16 : 0.7), location: 1),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .overlay(shape.strokeBorder(Color.black.opacity(dark ? 0.35 : 0.08), lineWidth: 0.5).padding(-0.5))
        .background(shape.fill(Color.black.opacity(0.001)).elevation(.float))
    }
}

/// The macOS arrow pointer.
struct LandingCursor: View {
    /// 0…1: how far a click has pressed it.
    var press: Double = 0

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 17.2))
            p.addLine(to: CGPoint(x: 4.1, y: 13.3))
            p.addLine(to: CGPoint(x: 6.9, y: 19.8))
            p.addLine(to: CGPoint(x: 9.6, y: 18.7))
            p.addLine(to: CGPoint(x: 6.8, y: 12.3))
            p.addLine(to: CGPoint(x: 12.4, y: 12.3))
            p.closeSubpath()
        }
        .fill(Color.black)
        .overlay(
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 17.2))
                p.addLine(to: CGPoint(x: 4.1, y: 13.3))
                p.addLine(to: CGPoint(x: 6.9, y: 19.8))
                p.addLine(to: CGPoint(x: 9.6, y: 18.7))
                p.addLine(to: CGPoint(x: 6.8, y: 12.3))
                p.addLine(to: CGPoint(x: 12.4, y: 12.3))
                p.closeSubpath()
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        )
        .frame(width: 13, height: 20, alignment: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1.5)
        .scaleEffect(1 - 0.12 * press, anchor: .topLeading)
        .frame(width: 13, height: 20, alignment: .topLeading)
    }
}

/// A key press shown for the viewer, since a video cannot show the keyboard.
struct LandingKeys: View {
    let keys: [String]
    let dark: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: key.count > 1 ? 15 : 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(dark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
                    .padding(.horizontal, key.count > 1 ? 12 : 0)
                    .frame(minWidth: 42, minHeight: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(dark ? Color.white.opacity(0.14) : Color.white.opacity(0.85))
                            .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 0, y: 2)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(dark ? 0.18 : 0.9), lineWidth: 0.5))
            }
        }
        .padding(10)
    }
}

/// The right end of a macOS menu bar: neutral system items, and room for
/// BarShelf's item at `itemRight`, which the caller draws.
struct LandingMenuBar {
    static let height: CGFloat = 24
    let width: CGFloat
    let dark: Bool
    var clock = "Thu Nov 12  4:48 PM"
    /// The app menus on the left (Finder, File, …); off for a crop of the
    /// right end alone.
    var showsMenus = true

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    /// The system items, right to left: (x of the item's centre, content).
    private var clockWidth: CGFloat {
        ceil(NSAttributedString(string: clock, attributes: [.font: Self.font]).size().width)
    }

    var clockX: CGFloat { width - 14 - clockWidth }
    var controlCenterX: CGFloat { clockX - 22 }
    var wifiX: CGFloat { controlCenterX - 30 }
    var batteryX: CGFloat { wifiX - 34 }
    /// Where BarShelf's item ends on the right.
    var itemRight: CGFloat { batteryX - 22 }

    var ink: Color { dark ? Color.white.opacity(0.95) : Color.black.opacity(0.85) }

    var view: some View {
        ZStack(alignment: .topLeading) {
            // A bar over the wallpaper: barely there, as in macOS 26.
            LinearGradient(colors: [(dark ? Color.black : Color.white).opacity(dark ? 0.18 : 0.22), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: width, height: Self.height)
            if showsMenus {
            HStack(spacing: 20) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text(verbatim: "Finder").font(.system(size: 13, weight: .bold))
                // No Help: zoomed in on the right, it would be cut in half.
                ForEach(["File", "Edit", "View", "Go", "Window"], id: \.self) { item in
                    Text(verbatim: item).font(.system(size: 13, weight: .medium))
                }
            }
            .frame(height: Self.height)
            .offset(x: 18)
            }
            Image(systemName: "battery.75percent").font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: Self.height).offset(x: batteryX - 15)
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: Self.height).offset(x: wifiX - 12)
            Image(systemName: "switch.2").font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: Self.height).offset(x: controlCenterX - 12)
            Text(verbatim: clock).font(Font(Self.font))
                .frame(height: Self.height).offset(x: clockX)
        }
        .foregroundStyle(ink)
        .frame(width: width, height: Self.height, alignment: .topLeading)
    }
}

// MARK: - The cluster in the menu bar

/// The cluster's motion, replayed the way `MenuBarController.setClusterFocus`
/// animates it: each change of focus glides positions, pill, lead and the
/// icon's fade from wherever they are over `focusDuration`, eased out.
struct LandingCluster {
    struct State {
        var focus: Int?
        var positions: [CGFloat]
        var pill: CGFloat
        var lead: CGFloat
        var markAlpha: CGFloat
    }

    let chips: [ClusterChip]
    /// (time, chip in focus or nil).
    let events: [(t: Double, focus: Int?)]

    private func target(_ focus: Int?) -> State {
        State(
            focus: focus,
            positions: MenuBarController.clusterTargets(chips, focus: focus),
            pill: focus == nil ? CGFloat(ClusterGeometry.disc) : MenuBarController.pillWidth(chips),
            lead: focus == nil ? 0 : MenuBarController.clusterLead(for: chips),
            markAlpha: ClusterGeometry(count: chips.count).hidesMark(focus: focus) ? 0 : 1
        )
    }

    private static func mix(_ a: State, _ b: State, _ e: CGFloat) -> State {
        State(
            focus: b.focus,
            positions: zip(a.positions, b.positions).map { $0 + ($1 - $0) * e },
            pill: a.pill + (b.pill - a.pill) * e,
            lead: (a.lead + (b.lead - a.lead) * e).rounded(),
            markAlpha: a.markAlpha + (b.markAlpha - a.markAlpha) * e
        )
    }

    func state(at t: Double) -> State {
        var start = target(nil), goal = start, began = -Double.infinity
        func progress(_ now: Double) -> CGFloat {
            CGFloat(1 - pow(1 - Ease.clamp((now - began) / MenuBarController.focusDuration), 3))
        }
        for event in events where event.t <= t {
            let current = Self.mix(start, goal, progress(event.t))
            start = current
            start.pill = CGFloat(ClusterGeometry.disc) // a new pill grows out of its disc
            goal = target(event.focus)
            began = event.t
        }
        return Self.mix(start, goal, progress(t))
    }

    /// The status item's image for `state`, rasterized at `scale`.
    func image(_ state: State, colors: [String: NSColor], dark: Bool, scale: CGFloat) -> LandingLayer? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let image = MenuBarController.clusterImage(
            chips, positions: state.positions, focus: state.focus, pill: state.pill, lead: state.lead,
            markAlpha: state.markAlpha,
            mark: BarShelfStatusIcon.image(for: AppPreferences.defaultMenuBarSymbol, fallback: "tray.full"),
            badged: false,
            color: { colors[$0.id] ?? .controlAccentColor },
            appearance: appearance,
            height: LandingMenuBar.height
        )
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: [
            .ctm: NSAffineTransform(transform: AffineTransform(scale: scale)),
        ]) else { return nil }
        return LandingLayer(image: cg, size: image.size)
    }

    /// Where the folded stack starts, for an item that ends at `itemRight`.
    func stackOrigin(itemRight: CGFloat) -> CGFloat {
        itemRight - MenuBarController.clusterItemInset - CGFloat(ClusterGeometry(count: chips.count).itemWidth)
    }

    /// A chip's rect in scene points when `focus` is settled: its pill when
    /// it is the focus, else its disc's slot.
    func chipRect(_ index: Int, focus: Int?, itemRight: CGFloat) -> CGRect {
        let x = MenuBarController.clusterTargets(chips, focus: focus)[index]
        let pill = index == focus ? MenuBarController.pillWidth(chips) : 0
        let width = max(pill + 2 * CGFloat(ClusterGeometry.slotInset), CGFloat(ClusterGeometry.slot))
        return CGRect(x: stackOrigin(itemRight: itemRight) + x, y: 0, width: width, height: LandingMenuBar.height)
    }

    /// The point a pointer rests on to hover a chip: its glyph.
    func chipPoint(_ index: Int, focus: Int?, itemRight: CGFloat) -> CGPoint {
        let rect = chipRect(index, focus: focus, itemRight: itemRight)
        let glyph = index == focus
            ? rect.minX + CGFloat(ClusterGeometry.slotInset) + MenuBarController.ChipMetrics.face * 0.55
            : rect.midX
        return CGPoint(x: glyph, y: LandingMenuBar.height / 2 + 1)
    }

    /// The BarShelf icon's centre while folded.
    func markPoint(itemRight: CGFloat) -> CGPoint {
        let geometry = ClusterGeometry(count: chips.count)
        return CGPoint(x: stackOrigin(itemRight: itemRight) + CGFloat(geometry.collapsedMarkX + ClusterGeometry.markWidth / 2),
                       y: LandingMenuBar.height / 2 + 1)
    }
}
#endif
