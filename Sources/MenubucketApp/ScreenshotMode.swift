import AppKit
import MenubucketCore
import SwiftUI

/// Headless screenshot generator: `barshelf screenshot <dir>` renders the
/// *actual* SwiftUI widget UI (real `ViewTreeRenderer`, real adapters) to PNGs
/// offscreen via `ImageRenderer` — no menu bar, no Screen Recording permission.
/// Produces authentic native renders for the landing page and README.
enum ScreenshotMode {
    @MainActor
    static func run(outputDir: String) -> Int32 {
        _ = NSApplication.shared // initialize AppKit (SF Symbols, fonts)
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var ok = true
        ok = render(PopoverShot(scheme: .dark), name: "popover-dark", to: dir) && ok
        ok = render(PopoverShot(scheme: .light), name: "popover-light", to: dir) && ok
        ok = render(BuilderShot(), name: "builder", to: dir) && ok
        // Standalone widget-card tiles for the landing-page preview gallery
        // (light — the landing page is a fixed light theme).
        let tiles: [(name: String, title: String, icon: String, node: UINode, accent: String?)] = [
            ("tile-today", "Today", "calendar", ShotData.todayNode, "red"),
            ("tile-weather", "Weather", "cloud.sun.fill", ShotData.weatherNode, "blue"),
            ("tile-battery", "Battery", "battery.100percent", ShotData.batteryNode, "green"),
            ("tile-otp", "OTP Codes", "key.fill", ShotData.otpNode, "purple"),
            ("tile-files", "Recent Files", "clock.arrow.circlepath", ShotData.filesNode, nil),
            ("tile-aas", "aas usage", "gauge", ShotData.aasNode, "orange"),
            ("tile-k8s", "k8s pods", "shippingbox", ShotData.k8sNode, nil),
        ]
        for tile in tiles {
            ok = render(
                TileShot(title: tile.title, icon: tile.icon, node: tile.node, accentName: tile.accent),
                name: tile.name,
                to: dir
            ) && ok
        }
        ok = composeHeroSet(dir: dir) && ok
        ok = renderMotion(dir: dir) && ok
        return ok ? 0 : 1
    }

    // MARK: - Motion demo (frame sequence → H.264 via ffmpeg)

    static let motionFPS = 24
    static let motionDuration = 8.0

    /// Renders the interaction demo — popover opens under the status item,
    /// swipes to the OTP page, copies a code (toast), closes — as a clean
    /// 8-second loop. Skipped when ffmpeg is not installed.
    @MainActor
    private static func renderMotion(dir: URL) -> Bool {
        guard let ffmpeg = findFFmpeg() else {
            FileHandle.standardError.write(Data("ffmpeg not found — skipping motion demo\n".utf8))
            return true
        }
        let frames = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-motion-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: frames) }

        let frameCount = Int(motionDuration * Double(motionFPS))
        for index in 0..<frameCount {
            let t = Double(index) / Double(motionFPS)
            let renderer = ImageRenderer(content: MotionShot(t: t))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("motion frame \(index) failed\n".utf8))
                return false
            }
            let name = String(format: "frame-%04d.png", index)
            do { try png.write(to: frames.appendingPathComponent(name)) } catch { return false }
        }

        let output = dir.appendingPathComponent("popover-demo.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-framerate", "\(motionFPS)",
            "-i", frames.appendingPathComponent("frame-%04d.png").path,
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23",
            "-movflags", "+faststart",
            output.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return false }
        guard process.terminationStatus == 0 else {
            FileHandle.standardError.write(Data("ffmpeg failed for motion demo\n".utf8))
            return false
        }
        print("wrote \(output.path)")
        return true
    }

    private static func findFFmpeg() -> String? {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: - Hero / showcase composites

    /// Old popover footprint inside `macos-menubar-popover.jpg` (2400×1350),
    /// measured from the shipped asset — the fresh render is composited at the
    /// same top-left so it fully covers the previous one.
    static let heroPanelOrigin = CGPoint(x: 1785, y: 25)
    static let heroPanelWidth: CGFloat = 363
    /// Transparent margin around the rendered panel (room for its shadow).
    static let heroPanelMargin: CGFloat = 40

    /// Re-composites the landing-page hero (`macos-menubar-popover.jpg`), the
    /// showcase crop (`macos-widget-shelf.jpg`, 840×720) and the og:image crop
    /// (`macos-menubar-popover-crop.jpg`, 1600×1078 at 2× panel scale) by
    /// drawing a fresh popover render over the existing photo. Skipped when
    /// the output directory has no hero photo (generic screenshot runs).
    @MainActor
    private static func composeHeroSet(dir: URL) -> Bool {
        let heroURL = dir.appendingPathComponent("macos-menubar-popover.jpg")
        guard FileManager.default.fileExists(atPath: heroURL.path) else { return true }
        guard let backdrop = NSImage(contentsOf: heroURL) else {
            FileHandle.standardError.write(Data("hero backdrop unreadable\n".utf8))
            return false
        }

        let panel1x = ImageRenderer(content: HeroPanel())
        panel1x.scale = 1
        let panel2x = ImageRenderer(content: HeroPanel())
        panel2x.scale = 2
        let bar1x = ImageRenderer(content: MenuBarStrip())
        bar1x.scale = 1
        let bar2x = ImageRenderer(content: MenuBarStrip())
        bar2x.scale = 2
        guard let panel = panel1x.nsImage, let panelSharp = panel2x.nsImage,
              let bar = bar1x.nsImage, let barSharp = bar2x.nsImage else {
            FileHandle.standardError.write(Data("hero panel render failed\n".utf8))
            return false
        }
        let origin = heroPanelOrigin
        let margin = heroPanelMargin
        let panelSize = panel.size
        let panelHeight = panelSize.height - margin * 2
        let barSize = bar.size

        // Full hero: photo, menu bar strip (hides the photo's baked-in menus,
        // anchors the popover to BarShelf's highlighted status item), panel.
        let hero = NSImage(size: NSSize(width: 2400, height: 1350), flipped: true) { _ in
            backdrop.draw(in: CGRect(x: 0, y: 0, width: 2400, height: 1350))
            bar.draw(in: CGRect(x: 0, y: 0, width: barSize.width, height: barSize.height))
            panel.draw(in: CGRect(
                x: origin.x - margin, y: origin.y - margin,
                width: panelSize.width, height: panelSize.height
            ))
            return true
        }

        // Showcase: 840×720 crop, menu bar included, panel roughly centered.
        let shelfOffset = CGPoint(x: origin.x - (840 - heroPanelWidth) / 2, y: 0)
        let shelf = NSImage(size: NSSize(width: 840, height: 720), flipped: true) { _ in
            hero.draw(in: CGRect(x: -shelfOffset.x, y: -shelfOffset.y, width: 2400, height: 1350))
            return true
        }

        // og:image: a zoomed 1600×1078 crop from the top strip — menu bar +
        // full panel with a little breathing room, both redrawn from the 2×
        // renders so the zoom stays sharp. The crop height adapts to the
        // panel's actual height; width follows the 1600:1078 aspect.
        // Snapped to the screen's right edge so the status cluster and clock
        // stay whole; the panel keeps a comfortable left margin.
        let cropHeight = origin.y + panelHeight + 16
        let cropWidth = cropHeight * 1600 / 1078
        let cropX = 2400 - cropWidth
        let scale = 1600 / cropWidth
        let og = NSImage(size: NSSize(width: 1600, height: 1078), flipped: true) { _ in
            hero.draw(in: CGRect(x: -cropX * scale, y: 0, width: 2400 * scale, height: 1350 * scale))
            barSharp.draw(in: CGRect(
                x: -cropX * scale, y: 0,
                width: barSize.width * scale, height: barSize.height * scale
            ))
            panelSharp.draw(in: CGRect(
                x: (origin.x - margin - cropX) * scale,
                y: (origin.y - margin) * scale,
                width: panelSize.width * scale, height: panelSize.height * scale
            ))
            return true
        }

        var ok = writeJPEG(hero, to: dir.appendingPathComponent("macos-menubar-popover.jpg"))
        ok = writeJPEG(shelf, to: dir.appendingPathComponent("macos-widget-shelf.jpg")) && ok
        ok = writeJPEG(og, to: dir.appendingPathComponent("macos-menubar-popover-crop.jpg")) && ok
        return ok
    }

    private static func writeJPEG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        else {
            FileHandle.standardError.write(Data("jpeg encode failed: \(url.lastPathComponent)\n".utf8))
            return false
        }
        do {
            try jpeg.write(to: url)
            print("wrote \(url.path)")
            return true
        } catch {
            FileHandle.standardError.write(Data("write failed \(url.lastPathComponent): \(error)\n".utf8))
            return false
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, name: String, to dir: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("screenshot failed: \(name)\n".utf8))
            return false
        }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("wrote \(url.path)")
            return true
        } catch {
            FileHandle.standardError.write(Data("write failed \(name): \(error)\n".utf8))
            return false
        }
    }
}

// MARK: - Sample data (authentic: rendered by the real ViewTreeRenderer)

private enum ShotData {
    /// Real `AasUsageAdapter` output from representative JSON.
    static var aasNode: UINode {
        let reset = Int(Date().timeIntervalSince1970 * 1000) + 3_600_000
        let json = """
        {"accounts":[
          {"provider":"claude","name":"work-01","email":null,"active":true,"plan":"max","planLabel":"Max","headline":"","error":null,"meters":[{"label":"5h","usedPct":64,"resetMs":\(reset)}]},
          {"provider":"claude","name":"personal","email":null,"active":false,"plan":"pro","planLabel":"Pro","headline":"","error":null,"meters":[{"label":"5h","usedPct":82,"resetMs":\(reset)}]},
          {"provider":"codex","name":"team-x","email":null,"active":false,"plan":null,"planLabel":null,"headline":"","error":null,"meters":[{"label":"5h","usedPct":94,"resetMs":\(reset)}]}
        ]}
        """
        return AasUsageAdapter.adapt(Data(json.utf8))
    }

    static var otpNode: UINode {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let json = """
        {"type":"list","spacing":3,"items":[
          {"type":"hstack","id":"gh","spacing":10,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"key.fill"},"size":18,"tint":"warning"},
            {"type":"vstack","spacing":1,"widthFill":true,"children":[
              {"type":"text","text":"GitHub","role":"body"},
              {"type":"text","text":"aws-root","role":"caption"}]},
            {"type":"progress","style":"ring","countdown":{"from":\(now),"until":\(now + 21000)},"labelFrom":"remainingSeconds","size":22},
            {"type":"text","text":"728 419","role":"code","monospacedDigit":true}]},
          {"type":"hstack","id":"cf","spacing":10,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"key.fill"},"size":18,"tint":"secondary"},
            {"type":"vstack","spacing":1,"widthFill":true,"children":[
              {"type":"text","text":"Cloudflare","role":"body"},
              {"type":"text","text":"infra","role":"caption"}]},
            {"type":"progress","style":"ring","countdown":{"from":\(now),"until":\(now + 9000)},"labelFrom":"remainingSeconds","size":22,"tintRules":[{"whenRemainingLtSeconds":10,"tint":"danger"}]},
            {"type":"text","text":"113 907","role":"code","monospacedDigit":true,"foreground":"danger"}]}
        ]}
        """
        return (try? JSONDecoder().decode(UINode.self, from: Data(json.utf8))) ?? UINode(type: "spacer")
    }

    static var filesNode: UINode {
        let json = """
        {"type":"list","spacing":3,"items":[
          {"type":"hstack","id":"f1","spacing":9,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"photo"},"size":20,"tint":"accent"},
            {"type":"vstack","spacing":1,"widthFill":true,"children":[
              {"type":"text","text":"Screenshot 2026-07-09.png","role":"body","lineLimit":1},
              {"type":"text","text":"2 minutes ago","role":"caption","foreground":"tertiary"}]}]},
          {"type":"hstack","id":"f2","spacing":9,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"doc.fill"},"size":20,"tint":"secondary"},
            {"type":"vstack","spacing":1,"widthFill":true,"children":[
              {"type":"text","text":"invoice-june.pdf","role":"body","lineLimit":1},
              {"type":"text","text":"1 hour ago","role":"caption","foreground":"tertiary"}]}]}
        ]}
        """
        return (try? JSONDecoder().decode(UINode.self, from: Data(json.utf8))) ?? UINode(type: "spacer")
    }

    private static func decode(_ json: String) -> UINode {
        (try? JSONDecoder().decode(UINode.self, from: Data(json.utf8))) ?? UINode(type: "spacer")
    }

    static var todayNode: UINode {
        decode("""
        {"type":"hstack","spacing":10,"children":[
          {"type":"vstack","spacing":0,"children":[
            {"type":"text","text":"Thursday","role":"caption","foreground":"danger"},
            {"type":"text","text":"09","size":40,"role":"title"}]},
          {"type":"spacer"},
          {"type":"vstack","spacing":2,"children":[
            {"type":"text","text":"20:53","size":30,"role":"title","monospacedDigit":true},
            {"type":"text","text":"Jul 2026","role":"caption","foreground":"secondary"}]}]}
        """)
    }

    static var batteryNode: UINode {
        // No inner "Battery" caption — the card header already names the widget.
        decode("""
        {"type":"vstack","spacing":6,"children":[
          {"type":"text","text":"80%","size":40,"role":"title","monospacedDigit":true},
          {"type":"text","text":"2:10 on battery","role":"caption","foreground":"secondary"},
          {"type":"progress","style":"linear","value":0.8,"tint":"good"}]}
        """)
    }

    static var weatherNode: UINode {
        // No inner weather glyph — the card header already carries one.
        decode("""
        {"type":"vstack","spacing":2,"children":[
          {"type":"text","text":"Seoul","role":"caption","foreground":"secondary"},
          {"type":"text","text":"24°","size":44,"role":"title","monospacedDigit":true},
          {"type":"text","text":"Cloudy","role":"caption","foreground":"secondary"}]}
        """)
    }

    static var k8sNode: UINode {
        let json = """
        {"type":"list","spacing":3,"items":[
          {"type":"hstack","id":"p1","spacing":8,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"circle.fill"},"size":9,"tint":"good"},
            {"type":"text","text":"api-7f9c","role":"body","widthFill":true},
            {"type":"text","text":"Running","role":"caption"}]},
          {"type":"hstack","id":"p2","spacing":8,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"circle.fill"},"size":9,"tint":"good"},
            {"type":"text","text":"web-2b1d","role":"body","widthFill":true},
            {"type":"text","text":"Running","role":"caption"}]},
          {"type":"hstack","id":"p3","spacing":8,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"circle.fill"},"size":9,"tint":"warning"},
            {"type":"text","text":"job-x0","role":"body","widthFill":true},
            {"type":"text","text":"Pending","role":"caption"}]}
        ]}
        """
        return (try? JSONDecoder().decode(UINode.self, from: Data(json.utf8))) ?? UINode(type: "spacer")
    }
}

// MARK: - Popover composition (mirrors the real RootView chrome)

private struct ShotCard: View {
    let title: String
    let icon: String
    let node: UINode
    var accentName: String? = nil

    private var accent: Color { WidgetAppearance(accent: accentName).accentColor ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(accent)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            ViewTreeRenderer(node: node)
                .environment(\.widgetAppearance, WidgetAppearance(accent: accentName))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Motion demo composition

/// Smoothstep easing over [from, to], clamped.
private func ramp(_ t: Double, _ from: Double, _ to: Double) -> Double {
    let x = min(max((t - from) / (to - from), 0), 1)
    return x * x * (3 - 2 * x)
}

/// One frame of the interaction demo at time `t` (seconds). Everything is a
/// pure function of `t`, so the frame sequence is deterministic:
/// 0.25s press the status item · 0.5s popover opens · 2.6s swipe to the OTP
/// page · 4.7s copy a code · 5.0s toast · 7.4s popover closes (clean loop).
private struct MotionShot: View {
    let t: Double

    var body: some View {
        let appear = min(ramp(t, 0.5, 0.9), 1 - ramp(t, 7.4, 7.9))
        let highlight = min(ramp(t, 0.25, 0.45), 1 - ramp(t, 7.55, 7.85))
        let toastAlpha = min(ramp(t, 5.0, 5.3), 1 - ramp(t, 6.7, 7.1))
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.15, blue: 0.18),
                    Color(red: 0.045, green: 0.065, blue: 0.085),
                ],
                startPoint: .top, endPoint: .bottom
            )
            MotionMenuBar(highlight: highlight)
            MotionPanel(t: t)
                .scaleEffect(0.96 + 0.04 * appear, anchor: .top)
                .opacity(appear)
                .offset(x: 401, y: 25)
            if toastAlpha > 0 {
                Text("Copied — clears in 30s")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .opacity(toastAlpha)
                    .position(x: 571, y: 438 - 6 * toastAlpha)
            }
        }
        .frame(width: 840, height: 720)
        .environment(\.colorScheme, .light)
    }
}

private struct MotionMenuBar: View {
    let highlight: Double

    var body: some View {
        ZStack {
            Color(red: 0.086, green: 0.11, blue: 0.125)
            HStack(spacing: 14) {
                Image(systemName: "apple.logo").font(.system(size: 13))
                Text("Finder").font(.system(size: 13, weight: .bold))
                Text("File").font(.system(size: 13))
                Text("Edit").font(.system(size: 13))
                Text("View").font(.system(size: 13))
                Spacer()
            }
            .padding(.leading, 16)
            HStack(spacing: 12) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.28 * highlight))
                    Image(nsImage: BarShelfStatusIcon.logoImage()).renderingMode(.template)
                }
                .frame(width: 34, height: 20)
                Image(systemName: "wifi").font(.system(size: 12)).frame(width: 24)
                HStack(spacing: 4) {
                    Text("80%").font(.system(size: 12.5))
                    Image(systemName: "battery.75percent").font(.system(size: 13))
                }
                .frame(width: 58)
                Text("Thu 9 Jul").font(.system(size: 13)).frame(width: 64)
                Text("20:53").font(.system(size: 13)).frame(width: 44)
            }
            .padding(.trailing, 14)
        }
        .foregroundColor(.white.opacity(0.92))
        .frame(width: 840, height: 24)
        .environment(\.colorScheme, .dark)
    }
}

/// The demo popover: two pages in a sliding strip (Home → Security), page
/// title crossfading with the swipe, live countdown rings, and a copy pulse
/// on the first OTP row.
private struct MotionPanel: View {
    let t: Double
    static let pageWidth: CGFloat = 340
    static let pageHeight: CGFloat = 392

    var body: some View {
        let swipe = ramp(t, 2.6, 3.3)
        VStack(spacing: 0) {
            HStack {
                // Sequential fade (out, then in) so the titles never overlap
                // mid-swipe into a double exposure.
                ZStack(alignment: .leading) {
                    Text("Home").opacity(1 - min(swipe / 0.4, 1))
                    Text("Security").opacity(max((swipe - 0.6) / 0.4, 0))
                }
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                homePage.frame(width: Self.pageWidth, height: Self.pageHeight, alignment: .top)
                securityPage.frame(width: Self.pageWidth, height: Self.pageHeight, alignment: .top)
            }
            .offset(x: -swipe * Self.pageWidth)
            .frame(width: Self.pageWidth, height: Self.pageHeight, alignment: .topLeading)
            .clipped()
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(.secondary)
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                Spacer()
                Circle().fill(swipe < 0.5 ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Circle().fill(swipe < 0.5 ? Color.secondary.opacity(0.35) : Color.accentColor)
                    .frame(width: 6, height: 6)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
                Image(systemName: "gearshape").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: Self.pageWidth)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var homePage: some View {
        VStack(spacing: 0) {
            ShotCard(title: "Today", icon: "calendar", node: ShotData.todayNode, accentName: "red")
            Divider().padding(.horizontal, 12)
            HStack(alignment: .top, spacing: 0) {
                ShotCard(title: "Weather", icon: "cloud.sun.fill", node: ShotData.weatherNode, accentName: "blue")
                Divider()
                ShotCard(title: "Battery", icon: "battery.100percent", node: ShotData.batteryNode, accentName: "green")
            }
            Divider().padding(.horizontal, 12)
            ShotCard(title: "Recent Files", icon: "clock.arrow.circlepath", node: ShotData.filesNode)
        }
        .padding(.vertical, 4)
    }

    private var securityPage: some View {
        let elapsed = max(0, t - 1.0)
        let pulse = min(ramp(t, 4.7, 4.85), 1 - ramp(t, 4.95, 5.2))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(.purple)
                Text("OTP Codes").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            otpRow("G", "GitHub", "aws-root", code: "728 419", remaining: 19.5 - elapsed, pulse: pulse)
            otpRow("C", "Cloudflare", "infra", code: "245 108", remaining: 26.5 - elapsed, pulse: 0)
            otpRow("T", "Tailscale", "ops@corp", code: "113 907", remaining: 8.5 - elapsed, pulse: 0)
            otpRow("G", "Google", "personal", code: "094 771", remaining: 23.0 - elapsed, pulse: 0)
            otpRow("A", "AWS", "root@acme", code: "512 380", remaining: 14.5 - elapsed, pulse: 0)
            otpRow("S", "Slack", "team-x", code: "667 042", remaining: 27.5 - elapsed, pulse: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func otpRow(
        _ letter: String, _ issuer: String, _ account: String,
        code: String, remaining: Double, pulse: Double
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4.4)
                .fill(Color.purple.opacity(0.16))
                .frame(width: 20, height: 20)
                .overlay(
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.purple)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(issuer).font(.system(size: 12))
                Text(account).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.purple.opacity(0.08 + 0.28 * pulse))
                )
            MotionRing(remaining: remaining)
        }
        .padding(.vertical, 3)
    }
}

private struct MotionRing: View {
    let remaining: Double
    static let period = 30.0

    var body: some View {
        let fraction = min(max(remaining / Self.period, 0), 1)
        let tint = remaining < 10 ? Color.red : Color.purple
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(max(Int(remaining.rounded(.up)), 0))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(tint)
        }
        .frame(width: 25, height: 25)
    }
}

/// The macOS menu bar composited across the hero photo's top strip — replaces
/// the stray app menus baked into the photo and gives the popover an anchor:
/// BarShelf's real status mark (highlighted, pressed state) sits right above
/// the panel, among ordinary status items.
private struct MenuBarStrip: View {
    var body: some View {
        ZStack {
            // Opaque so the photo's original menu bar text cannot ghost through;
            // the dark blue-gray reads as the translucent bar over a night scene.
            Color(red: 0.086, green: 0.11, blue: 0.125)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 13))
                Text("Finder").font(.system(size: 13, weight: .bold))
                Group {
                    Text("File"); Text("Edit"); Text("View"); Text("Go"); Text("Window"); Text("Help")
                }
                .font(.system(size: 13))
                Spacer()
            }
            .padding(.leading, 18)
            HStack(spacing: 12) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.28))
                    Image(nsImage: BarShelfStatusIcon.logoImage())
                        .renderingMode(.template)
                }
                .frame(width: 34, height: 20)
                Image(systemName: "moon.fill").font(.system(size: 12)).frame(width: 22)
                Image(systemName: "display").font(.system(size: 12)).frame(width: 22)
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).frame(width: 22)
                Image(systemName: "wifi").font(.system(size: 12)).frame(width: 24)
                HStack(spacing: 4) {
                    Text("80%").font(.system(size: 12.5))
                    Image(systemName: "battery.75percent").font(.system(size: 13))
                }
                .frame(width: 58)
                Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 22)
                Image(systemName: "switch.2").font(.system(size: 12)).frame(width: 26)
                Text("Thu 9 Jul").font(.system(size: 13)).frame(width: 64)
                Text("20:53").font(.system(size: 13)).frame(width: 44)
            }
            .padding(.trailing, 14)
        }
        .foregroundColor(.white.opacity(0.92))
        .frame(width: 2400, height: 24)
        .environment(\.colorScheme, .dark)
    }
}

/// The popover panel composited into the hero photo: same chrome as
/// `PopoverShot` but bare (no padding/backdrop) with a night-friendly shadow.
/// Must render at least ~470 pt tall to fully cover the old baked-in popover.
private struct HeroPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Home").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            VStack(spacing: 0) {
                ShotCard(title: "Today", icon: "calendar", node: ShotData.todayNode, accentName: "red")
                Divider().padding(.horizontal, 12)
                HStack(alignment: .top, spacing: 0) {
                    ShotCard(title: "Weather", icon: "cloud.sun.fill", node: ShotData.weatherNode, accentName: "blue")
                    Divider()
                    ShotCard(title: "Battery", icon: "battery.100percent", node: ShotData.batteryNode, accentName: "green")
                }
                Divider().padding(.horizontal, 12)
                ShotCard(title: "k8s pods", icon: "shippingbox", node: ShotData.k8sNode)
                Divider().padding(.horizontal, 12)
                ShotCard(title: "Recent Files", icon: "clock.arrow.circlepath", node: ShotData.filesNode)
            }
            .padding(.vertical, 4)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundColor(.secondary)
                Image(systemName: "chevron.left").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                Spacer()
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
                Image(systemName: "gearshape").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: ScreenshotMode.heroPanelWidth)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .padding(ScreenshotMode.heroPanelMargin)
        .environment(\.colorScheme, .light)
    }
}

/// One widget card as a standalone tile — the landing page's preview gallery.
/// Transparent margins around a bordered panel, so the tile sits on any page
/// background.
private struct TileShot: View {
    let title: String
    let icon: String
    let node: UINode
    var accentName: String? = nil

    var body: some View {
        ShotCard(title: title, icon: icon, node: node, accentName: accentName)
            .frame(width: 280)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(4)
            .environment(\.colorScheme, .light)
    }
}

private struct PopoverShot: View {
    let scheme: ColorScheme
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Demo").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.secondary)
                Text("‹ 1 / 3 ›").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            VStack(spacing: 0) {
                ShotCard(title: "Today", icon: "calendar", node: ShotData.todayNode, accentName: "red")
                Divider().padding(.horizontal, 12)
                HStack(alignment: .top, spacing: 0) {
                    ShotCard(title: "Battery", icon: "battery.100percent", node: ShotData.batteryNode, accentName: "green")
                    Divider()
                    ShotCard(title: "Weather", icon: "cloud.sun.fill", node: ShotData.weatherNode, accentName: "blue")
                }
                Divider().padding(.horizontal, 12)
                ShotCard(title: "aas usage", icon: "gauge", node: ShotData.aasNode, accentName: "orange")
            }
            .padding(.vertical, 4)
            Divider()
            HStack(spacing: 7) {
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            }
            .padding(9)
        }
        .frame(width: 360)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(20)
        .background(shotBackground)
        .environment(\.colorScheme, scheme)
    }

    private var shotBackground: some View {
        (scheme == .dark ? Color(red: 0.04, green: 0.10, blue: 0.12) : Color(red: 0.93, green: 0.96, blue: 0.95))
    }
}

// MARK: - Builder composition

private struct BuilderShot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.95, green: 0.47, blue: 0.37)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.96, green: 0.78, blue: 0.35)).frame(width: 11, height: 11)
                Circle().fill(Color(red: 0.35, green: 0.84, blue: 0.60)).frame(width: 11, height: 11)
                Text("Create Widget").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 6)
            }
            .padding(12)
            Divider()
            HStack(spacing: 8) {
                stepView("✓", "Source", done: true)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 16, height: 1)
                stepView("2", "Display", now: true)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 16, height: 1)
                stepView("3", "Details")
            }
            .padding(.horizontal, 16).padding(.top, 14)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 10) {
                    optRow("List", selected: true)
                    optRow("Table")
                    optRow("Single value")
                    optRow("Plain text")
                }
                .padding(16).frame(width: 220)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIVE PREVIEW").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.secondary).tracking(1)
                    ShotCard(title: "k8s pods", icon: "shippingbox", node: ShotData.k8sNode)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(20)
        .background(Color(red: 0.04, green: 0.10, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }

    private func stepView(_ num: String, _ label: String, done: Bool = false, now: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(num)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 19, height: 19)
                .background(Circle().fill(done ? Color.accentColor : (now ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2))))
                .foregroundColor(done ? Color(nsColor: .windowBackgroundColor) : (now ? .accentColor : .secondary))
            Text(label).font(.system(size: 12)).foregroundColor(now || done ? .primary : .secondary)
        }
    }

    private func optRow(_ label: String, selected: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(selected ? .primary : .secondary)
            Spacer()
            if selected { Image(systemName: "checkmark").font(.system(size: 11)).foregroundColor(.accentColor) }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
    }
}
