#if DEBUG
import AppKit
import MenubucketCore
import SwiftUI
@testable import MenubucketApp

/// `barshelf-app landing-media <dir> film | film-keynote | film-trailer | film-preview`:
/// the landing page's short film, cut from the same plates as the clips
/// (`LandingPlate`) plus the film's own scenes (`LandingFilmPlates.swift`).
///
/// A film is a list of shots and a list of captions. Each shot plays one
/// plate over a stretch of film time, at its own speed, framed by a camera
/// that moves between keyframes (scale, offset, a 3D tilt); shots overlap
/// by the style's transition. Title and end cards are drawn by the film
/// itself. Two styles share the plates and differ in everything else:
/// pacing, ground, how the plate sits, the type, the transitions.
///
/// Frames are a pure function of time, like the clips.
@MainActor
struct LandingFilm {
    let demo: LandingDemo
    let style: Style

    enum Style: String, CaseIterable {
        /// Dark, slow, large type, blurred dissolves.
        case keynote
        /// Bright, fast, sticker captions, punch-in cuts.
        case trailer
    }

    /// Film frame in points; rendered at `scale`.
    static let size = CGSize(width: 960, height: 540)
    static let scale: CGFloat = 2
    static let fps = 30

    /// A third-party widget the build scene shows: a CLI's JSON, rendered.
    static let aasID = "dev.example.aas-usage"

    // MARK: - Shots

    enum Source {
        case title([String])
        case clutter
        case hero
        case popup
        case build
        case places
        case trust
        case end
    }

    struct Camera {
        var scale: CGFloat = 1
        var x: CGFloat = 0
        var y: CGFloat = 0
        /// Degrees about the horizontal and vertical axes.
        var tiltX: Double = 0
        var tiltY: Double = 0

        static func mix(_ a: Camera, _ b: Camera, _ e: Double) -> Camera {
            let f = CGFloat(e)
            return Camera(scale: a.scale + (b.scale - a.scale) * f, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f,
                          tiltX: a.tiltX + (b.tiltX - a.tiltX) * e, tiltY: a.tiltY + (b.tiltY - a.tiltY) * e)
        }
    }

    struct Shot {
        let source: Source
        /// Film time the shot is on screen.
        let start: Double
        let end: Double
        /// Plate time at `start`, and plate seconds per film second.
        var plateFrom: Double = 0
        var speed: Double = 1
        /// Camera keyframes in shot-local seconds.
        var camera: [(t: Double, cam: Camera)] = [(0, Camera())]

        func plateTime(_ t: Double) -> Double { plateFrom + (t - start) * speed }

        func cameraAt(_ t: Double) -> Camera {
            let local = t - start
            guard let first = camera.first else { return Camera() }
            guard local > first.t else { return first.cam }
            for (a, b) in zip(camera, camera.dropFirst()) where local <= b.t {
                return Camera.mix(a.cam, b.cam, Ease.inOut(local, a.t, b.t))
            }
            return camera.last!.cam
        }
    }

    struct Caption {
        let text: String
        let start: Double
        let end: Double
    }

    /// The cut: shots, captions, and how long transitions take.
    struct Cut {
        let shots: [Shot]
        let captions: [Caption]
        let transition: Double
        var duration: Double { shots.map(\.end).max() ?? 0 }
    }

    static func cut(_ style: Style) -> Cut {
        switch style {
        case .keynote:
            return Cut(shots: [
                Shot(source: .title(["Your", "menu bar", "is full."]), start: 0, end: 2.6),
                Shot(source: .clutter, start: 2.0, end: 7.0, plateFrom: 0, speed: 1,
                     camera: [(0, Camera(scale: 1.45, x: -60, tiltX: 8)), (2.2, Camera(scale: 1.25, x: -30, tiltX: 4)),
                              (5.0, Camera(scale: 1.0))]),
                Shot(source: .hero, start: 6.4, end: 18.2, plateFrom: 0.5, speed: 1,
                     // In on the chips while the pointer sweeps them, out
                     // as the card opens.
                     camera: [(0, Camera(scale: 0.86, y: 10, tiltX: 14, tiltY: -16)),
                              (1.3, Camera(scale: 1.35, x: -89, y: 112)), (4.3, Camera(scale: 1.35, x: -89, y: 112)),
                              (5.6, Camera(scale: 0.95)), (9.5, Camera(scale: 0.95, tiltY: 6)),
                              (11.8, Camera(scale: 0.9, tiltX: 6, tiltY: 12))]),
                Shot(source: .popup, start: 17.6, end: 25.6, plateFrom: 0.9, speed: 1.18,
                     camera: [(0, Camera(scale: 0.9, x: 40, tiltY: 14)), (1.6, Camera(scale: 0.95)),
                              (5.0, Camera(scale: 1.04, x: -30, y: 20)), (8.0, Camera(scale: 0.95, tiltY: -10))]),
                Shot(source: .build, start: 25.0, end: 32.2, plateFrom: 0, speed: 1,
                     camera: [(0, Camera(scale: 0.88, tiltX: 10)), (2.4, Camera(scale: 0.96, x: 40)),
                              (5.0, Camera(scale: 0.98, x: -30)), (7.2, Camera(scale: 0.93))]),
                Shot(source: .places, start: 31.6, end: 38.0, plateFrom: 0, speed: 1,
                     camera: [(0, Camera(scale: 0.9, y: -30, tiltX: -12)), (2.0, Camera(scale: 0.95)),
                              (6.4, Camera(scale: 1.0, y: -20))]),
                Shot(source: .trust, start: 37.4, end: 41.8, plateFrom: 0, speed: 1,
                     camera: [(0, Camera(scale: 0.94, tiltY: 10)), (4.4, Camera(scale: 0.98, tiltY: -6))]),
                Shot(source: .end, start: 41.2, end: 46.0),
            ], captions: [
                Caption(text: "Fold it into one.", start: 4.4, end: 6.8),
                Caption(text: "Every reading at a glance.", start: 7.4, end: 11.0),
                Caption(text: "Click for the whole story.", start: 11.8, end: 15.6),
                Caption(text: "The whole shelf, from the keyboard.", start: 19.0, end: 24.8),
                Caption(text: "Any command becomes a widget.", start: 26.0, end: 31.4),
                Caption(text: "On your desktop. In your dock.", start: 32.4, end: 37.2),
                Caption(text: "It asks first, and keeps the record.", start: 38.0, end: 41.2),
            ], transition: 0.6)
        case .trailer:
            return Cut(shots: [
                Shot(source: .title(["Menu bar", "chaos?"]), start: 0, end: 1.6),
                Shot(source: .clutter, start: 1.4, end: 4.6, plateFrom: 0.6, speed: 1.3,
                     camera: [(0, Camera(scale: 1.5, x: -80, tiltY: -10)), (1.4, Camera(scale: 1.1, x: -10)),
                              (3.2, Camera(scale: 1.0, tiltY: 6))]),
                Shot(source: .hero, start: 4.4, end: 12.4, plateFrom: 0.7, speed: 1.42,
                     camera: [(0, Camera(scale: 1.5, x: -60, y: 150, tiltX: 18, tiltY: -22)),
                              (0.6, Camera(scale: 1.35, x: -89, y: 132, tiltY: -6)), (2.7, Camera(scale: 1.35, x: -89, y: 132, tiltY: 4)),
                              (3.6, Camera(scale: 1.0, tiltY: 8)), (6.0, Camera(scale: 0.96, tiltX: 8, tiltY: -10)),
                              (8.0, Camera(scale: 1.08, tiltY: 14))]),
                Shot(source: .popup, start: 12.2, end: 18.0, plateFrom: 1.0, speed: 1.55,
                     camera: [(0, Camera(scale: 1.14, tiltY: 20)), (0.6, Camera(scale: 0.98, tiltY: 4)),
                              (3.4, Camera(scale: 1.08, x: -30, y: 30)), (5.8, Camera(scale: 0.96, tiltY: -14))]),
                Shot(source: .build, start: 17.8, end: 22.8, plateFrom: 0.2, speed: 1.36,
                     camera: [(0, Camera(scale: 1.12, tiltX: -14)), (0.6, Camera(scale: 0.98)), (5.0, Camera(scale: 1.04, x: -40, tiltY: 10))]),
                Shot(source: .places, start: 22.6, end: 27.0, plateFrom: 0.2, speed: 1.35,
                     camera: [(0, Camera(scale: 1.12, y: -40, tiltX: -16)), (0.6, Camera(scale: 0.98)), (4.4, Camera(scale: 1.04, tiltY: -8))]),
                Shot(source: .trust, start: 26.8, end: 30.0, plateFrom: 0.2, speed: 1.3,
                     camera: [(0, Camera(scale: 1.12, tiltY: 16)), (0.6, Camera(scale: 0.98)), (3.2, Camera(scale: 1.03))]),
                Shot(source: .end, start: 29.8, end: 33.4),
            ], captions: [
                Caption(text: "Fold it.", start: 2.6, end: 4.4),
                Caption(text: "Glance.", start: 5.4, end: 8.2),
                Caption(text: "Click.", start: 8.6, end: 12.0),
                Caption(text: "Search. Swipe. Arrow keys.", start: 13.2, end: 17.6),
                Caption(text: "CLI → widget", start: 18.6, end: 22.4),
                Caption(text: "Desktop + Dock", start: 23.4, end: 26.6),
                Caption(text: "Asks first.", start: 27.4, end: 29.8),
            ], transition: 0.28)
        }
    }

    // MARK: - Recording

    /// Records the film (or, for `preview`, a few stills from it) into `dir`.
    /// The style the landing page shows (`film` writes it as film.*).
    static let landing: Style = .trailer

    func record(to dir: URL, ffmpeg: String, previewTimes: [Double]? = nil, name: String? = nil) -> Bool {
        let cut = Self.cut(style)
        stageExtras()
        let dark = style == .keynote
        var plates: [String: LandingPlate] = [
            "clutter": LandingClutterPlate(demo: demo, dark: true, scale: 4.5),
            "hero": LandingHeroClip(demo: demo, scale: 3),
            "popup": LandingPopupClip(demo: demo, scale: 2.5, dark: false),
            "build": LandingBuildPlate(demo: demo, scale: 3),
            "places": LandingPlacesPlate(demo: demo, dark: !dark, scale: 3),
            "trust": LandingTrustPlate(demo: demo, scale: 3),
        ]
        for (name, plate) in plates where !plate.prepare() {
            FileHandle.standardError.write(Data("landing-media: film plate \(name) failed\n".utf8))
            plates[name] = nil
            return false
        }
        let pixels = CGSize(width: Self.size.width * Self.scale, height: Self.size.height * Self.scale)
        let name = name ?? "film-\(style.rawValue)"

        if let previewTimes {
            var ok = true
            for t in previewTimes {
                guard let frame = frame(at: t, cut: cut, plates: plates) else { return false }
                ok = LandingMediaMode.writeJPEG(frame, to: dir.appendingPathComponent("\(name)-\(String(format: "%05.2f", t)).jpg")) && ok
            }
            return ok
        }

        guard let encoder = LandingEncoder(
            ffmpeg: ffmpeg, size: pixels, fps: Self.fps,
            mp4: dir.appendingPathComponent("\(name).mp4"),
            webm: dir.appendingPathComponent("\(name).webm"),
            crf: (mp4: 21, webm: 38)
        ) else { return false }
        let frames = Int(cut.duration * Double(Self.fps))
        let posterTime = style == .keynote ? 13.2 : 9.4
        var poster: CGImage?
        for index in 0..<frames {
            let t = Double(index) / Double(Self.fps)
            guard let frame = frame(at: t, cut: cut, plates: plates) else { return false }
            encoder.append(frame)
            if abs(t - posterTime) < 0.5 / Double(Self.fps) { poster = frame }
            if index % 150 == 0 { print("\(name): \(index)/\(frames)") }
        }
        guard encoder.finish() else { return false }
        if let poster { return LandingMediaMode.writeJPEG(poster, to: dir.appendingPathComponent("\(name).jpg")) }
        return true
    }

    /// The build scene's third-party widget joins the demo shelf.
    private func stageExtras() {
        let json = #"{"schemaVersion":1,"id":"\#(Self.aasID)","name":"aas usage","version":"1.0.0","icon":"gauge","entry":{"kind":"exec","main":"widget.sh"},"bucket":{"group":"Work","size":"M"},"appearance":{"accent":"orange"}}"#
        guard let manifest = try? Manifest.decode(from: Data(json.utf8)) else { return }
        let widget = LoadedWidget(manifest: manifest, directory: URL(fileURLWithPath: "/dev/null"),
                                  instanceID: Self.aasID, loadRevision: "landing")
        var renders = demo.widgets.map { demo.render($0.id, at: 0) }
        renders.append(WidgetSnapshot(widgetID: Self.aasID, viewTree: ShotData.aasNode, updatedAt: demo.now))
        demo.runtime.stagePreview(widgets: demo.widgets + [widget], renders: renders)
    }

    private func plateKey(_ source: Source) -> String? {
        switch source {
        case .clutter: return "clutter"
        case .hero: return "hero"
        case .popup: return "popup"
        case .build: return "build"
        case .places: return "places"
        case .trust: return "trust"
        case .title, .end: return nil
        }
    }

    private func frame(at t: Double, cut: Cut, plates: [String: LandingPlate]) -> CGImage? {
        var layers: [FilmFrame.Layer] = []
        for (index, shot) in cut.shots.enumerated() where t >= shot.start && t < shot.end {
            let isFirst = index == 0, isLast = index == cut.shots.count - 1
            let fadeIn = isFirst ? 1 : Ease.inOut(t, shot.start, shot.start + cut.transition)
            let fadeOut = isLast ? 1 : 1 - Ease.inOut(t, shot.end - cut.transition, shot.end)
            var content: FilmFrame.Content
            if let key = plateKey(shot.source), let plate = plates[key] {
                let plateT = min(max(shot.plateTime(t), 0), 60)
                guard let image = plate.frame(at: plateT) else { return nil }
                content = .plate(image, plate.size)
            } else if case .title(let words) = shot.source {
                content = .title(words, t - shot.start)
            } else {
                content = .end(t - shot.start)
            }
            layers.append(FilmFrame.Layer(content: content, camera: shot.cameraAt(t), fadeIn: fadeIn, fadeOut: fadeOut))
        }
        let captions = cut.captions.compactMap { caption -> (String, Double, Double)? in
            guard t >= caption.start - 0.05, t < caption.end + 0.4 else { return nil }
            return (caption.text, t - caption.start, caption.end - t)
        }
        let view = FilmFrame(style: style, t: t, layers: layers, captions: captions)
        return landingFrame(view, size: Self.size, scale: Self.scale)
    }
}

// MARK: - The frame

private struct FilmFrame: View {
    enum Content {
        case plate(CGImage, CGSize)
        case title([String], Double)
        case end(Double)
    }

    struct Layer {
        let content: Content
        let camera: LandingFilm.Camera
        let fadeIn: Double
        let fadeOut: Double
    }

    let style: LandingFilm.Style
    let t: Double
    let layers: [Layer]
    /// (text, seconds since it began, seconds until it ends).
    let captions: [(String, Double, Double)]

    private var size: CGSize { LandingFilm.size }
    private var keynote: Bool { style == .keynote }

    var body: some View {
        ZStack {
            FilmGround(style: style, t: t)
            ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                layerView(layer)
            }
            ForEach(Array(captions.enumerated()), id: \.offset) { index, caption in
                FilmCaption(style: style, text: caption.0, age: caption.1, left: caption.2, index: index)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func layerView(_ layer: Layer) -> some View {
        let a = min(layer.fadeIn, layer.fadeOut)
        let entering = layer.fadeIn < 1
        // Keynote: dissolve through a blur. Trailer: punch in from larger,
        // fall back smaller.
        let transitionScale: CGFloat = keynote
            ? 0.97 + 0.03 * CGFloat(a)
            : (entering ? 1 + 0.16 * CGFloat(1 - layer.fadeIn) : 0.9 + 0.1 * CGFloat(layer.fadeOut))
        let blur = keynote ? 16 * (1 - a) : 10 * (1 - a)
        switch layer.content {
        case .plate(let image, let plateSize):
            FilmPlate(style: style, image: image, plateSize: plateSize, camera: layer.camera)
                .scaleEffect(transitionScale)
                .blur(radius: blur)
                .opacity(a)
        case .title(let words, let age):
            FilmTitle(style: style, words: words, age: age)
                .blur(radius: blur)
                .opacity(a)
        case .end(let age):
            FilmEndCard(style: style, age: age)
                .opacity(a)
        }
    }
}

/// What lies behind every shot.
private struct FilmGround: View {
    let style: LandingFilm.Style
    let t: Double

    var body: some View {
        let size = LandingFilm.size
        if style == .keynote {
            ZStack {
                Color(red: 0.027, green: 0.03, blue: 0.055)
                // One slow glow drifting behind the plate.
                RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.7).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.5 + 0.18 * sin(t * 0.21), y: 0.55 + 0.1 * cos(t * 0.17)),
                               startRadius: 0, endRadius: size.width * 0.62)
                RadialGradient(colors: [Color(red: 0.9, green: 0.45, blue: 0.32).opacity(0.22), .clear],
                               center: UnitPoint(x: 0.85 - 0.1 * sin(t * 0.13), y: 0.9),
                               startRadius: 0, endRadius: size.width * 0.45)
            }
        } else {
            // Bright, and turning a little every second.
            let shift = t * 0.06
            LinearGradient(colors: [
                Color(hue: (0.04 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 1),
                Color(hue: (0.78 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.98),
                Color(hue: (0.5 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.92),
            ], startPoint: UnitPoint(x: 0, y: 0), endPoint: UnitPoint(x: 1, y: 1))
        }
    }
}

/// A plate on screen: the camera's scale, offset and tilt, the plate's own
/// frame (a floating screen, or a sticker with a hard shadow).
private struct FilmPlate: View {
    let style: LandingFilm.Style
    let image: CGImage
    let plateSize: CGSize
    let camera: LandingFilm.Camera

    var body: some View {
        let frame = LandingFilm.size
        // Fit: wide plates by width, the rest by height, with room around.
        let fit = min(frame.width * 0.84 / plateSize.width, frame.height * 0.84 / plateSize.height)
        let width = plateSize.width * fit, height = plateSize.height * fit
        let keynote = style == .keynote
        let radius: CGFloat = keynote ? 14 : 18
        Image(decorative: image, scale: CGFloat(image.width) / width)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(keynote ? 0.16 : 0.9), lineWidth: keynote ? 1 : 3))
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(keynote ? Color.black : Color(red: 0.12, green: 0.06, blue: 0.3))
                    .shadow(color: .black.opacity(keynote ? 0.65 : 0), radius: 40, y: 24)
                    .offset(x: keynote ? 0 : 12, y: keynote ? 0 : 14)
                    .opacity(keynote ? 1 : 0.85)
            )
            .rotation3DEffect(.degrees(camera.tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
            .rotation3DEffect(.degrees(camera.tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .scaleEffect(camera.scale)
            // Keynote: a little above centre, clear of the caption line.
            .offset(x: camera.x, y: camera.y + (keynote ? -18 : 10))
    }
}

/// Words that open the film, one after another.
private struct FilmTitle: View {
    let style: LandingFilm.Style
    let words: [String]
    let age: Double

    var body: some View {
        let keynote = style == .keynote
        VStack(spacing: keynote ? 2 : 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let start = 0.25 + Double(index) * (keynote ? 0.45 : 0.28)
                let e = keynote ? Ease.out(age, start, start + 0.7) : Ease.spring(age, start, duration: 0.42)
                Text(verbatim: word)
                    .font(.system(size: keynote ? 64 : 92, weight: keynote ? .bold : .black, design: keynote ? .default : .rounded))
                    .foregroundStyle(keynote ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color(red: 0.1, green: 0.04, blue: 0.24)))
                    .tracking(keynote ? -1.5 : -3)
                    .padding(.horizontal, keynote ? 0 : 18)
                    .background(keynote ? nil : Color.white.opacity(0.92).clipShape(RoundedRectangle(cornerRadius: 10)).rotationEffect(.degrees(index.isMultiple(of: 2) ? -2 : 1.5)))
                    .blur(radius: keynote ? 10 * (1 - e) : 0)
                    .opacity(keynote ? e : min(e * 2, 1))
                    .offset(y: keynote ? 24 * (1 - e) : 0)
                    .scaleEffect(keynote ? 1 : 1.6 - 0.6 * e)
            }
        }
    }
}

/// One caption: a quiet line under the picture (keynote), or a sticker
/// that slams in (trailer).
private struct FilmCaption: View {
    let style: LandingFilm.Style
    let text: String
    let age: Double
    let left: Double
    let index: Int

    var body: some View {
        let size = LandingFilm.size
        if style == .keynote {
            let e = min(Ease.out(age, 0, 0.6), Ease.out(left + 0.4, 0, 0.4))
            Text(verbatim: text)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 18)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.42)).blur(radius: 0.5))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
                .opacity(e)
                .blur(radius: 6 * (1 - e))
                .offset(y: 12 * (1 - e))
                .position(x: size.width / 2, y: size.height - 44)
        } else {
            let e = Ease.spring(age, 0, duration: 0.38)
            let out = Ease.out(left + 0.4, 0, 0.25)
            let colors = [Color(red: 1, green: 0.42, blue: 0.3), Color(red: 0.45, green: 0.32, blue: 1), Color(red: 0.05, green: 0.7, blue: 0.6)]
            Text(verbatim: text)
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors[text.count % colors.count]))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.85)).offset(x: 5, y: 6))
                .rotationEffect(.degrees(text.count.isMultiple(of: 2) ? -3 : 2.5))
                .scaleEffect(1.5 - 0.5 * e, anchor: .leading)
                .opacity(min(e * 2, 1) * out)
                .fixedSize()
                .frame(width: size.width - 80, alignment: .leading)
                .position(x: size.width / 2, y: 58)
        }
    }
}

/// The last card: the mark, the name, how to get it.
private struct FilmEndCard: View {
    let style: LandingFilm.Style
    let age: Double

    static let command = "brew install --cask open330/tap/barshelf"

    var body: some View {
        let keynote = style == .keynote
        let mark = Ease.spring(age, 0.1, duration: 0.7)
        let name = Ease.out(age, 0.45, 1.1)
        let typed = Int(max(0, (age - 1.2) / 0.03))
        let ink = keynote ? Color.white : Color(red: 0.1, green: 0.04, blue: 0.24)
        VStack(spacing: 18) {
            Image(nsImage: BarShelfStatusIcon.logoImage(size: NSSize(width: 96, height: 72)))
                .renderingMode(.template)
                .resizable()
                .frame(width: 96, height: 72)
                .foregroundStyle(ink)
                .shadow(color: (keynote ? Color(red: 0.7, green: 0.55, blue: 1) : .white).opacity(0.8 * sin(min(mark, 1) * .pi)), radius: 24)
                .scaleEffect(0.6 + 0.4 * mark)
                .opacity(min(mark * 1.5, 1))
            Text(verbatim: "BarShelf")
                .font(.system(size: 56, weight: keynote ? .bold : .black, design: keynote ? .default : .rounded))
                .tracking(-1.5)
                .foregroundStyle(ink)
                .opacity(name)
                .offset(y: 12 * (1 - name))
            HStack(spacing: 0) {
                Text(verbatim: "$ ").foregroundStyle(ink.opacity(0.5))
                Text(verbatim: String(Self.command.prefix(typed))).foregroundStyle(ink)
                Rectangle().fill(ink.opacity(Int(age * 2.2) % 2 == 0 ? 0.8 : 0)).frame(width: 9, height: 20)
            }
            .font(.system(size: 19, weight: .medium, design: .monospaced))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(keynote ? Color.white.opacity(0.07) : Color.white.opacity(0.75)))
            .opacity(Ease.out(age, 1.0, 1.4))
            Text(verbatim: "barshelf.jiun.dev")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink.opacity(0.6))
                .opacity(Ease.out(age, 2.4, 3.0))
        }
    }
}
#endif
