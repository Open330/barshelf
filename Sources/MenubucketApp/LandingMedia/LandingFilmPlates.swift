import AppKit
import MenubucketCore
import SwiftUI

// The film's own scenes. Like the clips, every surface that is BarShelf's is
// the real view (the cluster, cards, the dock, the permission card); the
// desktop, the menu bar's other items, the terminal and the pointer are
// staged. All of it is a pure function of time.

// MARK: - Clutter: a crowded menu bar folds into the cluster

/// The right end of a menu bar crowded with a dozen generic status icons,
/// which slide one by one into BarShelf's item until only the cluster is
/// left. The plate is the corner only — the film's camera shows it large.
@MainActor
final class LandingClutterPlate: LandingPlate {
    let demo: LandingDemo
    let dark: Bool
    let size = CGSize(width: 520, height: 64)
    let scale: CGFloat

    static let duration = 4.6
    /// When the icons start to fold, one after another, right to left.
    static let fold = 1.5
    static let stagger = 0.075
    static let travel = 0.42

    /// Generic stand-ins for the apps that crowd a menu bar.
    static let symbols = [
        "cloud", "music.note", "bolt.horizontal", "drop", "timer", "keyboard", "camera.metering.matrix",
        "externaldrive", "lock.shield", "paperplane", "waveform", "clipboard", "checklist",
        "globe", "thermometer.medium",
    ]

    private var wallpaper: LandingWallpaper!
    private var bar: LandingMenuBar!
    private var clusterLayer: LandingLayer?

    init(demo: LandingDemo, dark: Bool = true, scale: CGFloat = 4) {
        self.demo = demo
        self.dark = dark
        self.scale = scale
    }

    func prepare() -> Bool {
        // The desktop is the hero's, cropped to its top-right corner.
        guard let full = LandingWallpaper.make(size: LandingHeroClip.size, dark: dark) else { return false }
        wallpaper = full
        bar = LandingMenuBar(width: size.width, dark: dark, showsMenus: false)
        demo.stage(at: 0)
        let cluster = LandingCluster(chips: demo.clusterChips(), events: [])
        clusterLayer = cluster.image(cluster.state(at: 0), colors: demo.chipColors(cluster.chips), dark: dark, scale: scale)
        return clusterLayer != nil
    }

    func frame(at t: Double) -> CGImage? {
        guard let clusterLayer else { return nil }
        let clusterX = bar.itemRight - MenuBarController.clusterItemInset - clusterLayer.size.width
        let target = clusterX + clusterLayer.size.width * 0.3
        let count = Self.symbols.count
        // Icons sit left of BarShelf's item, 24 pt apart.
        let icons: [(symbol: String, x: CGFloat, alpha: Double, scale: CGFloat)] = Self.symbols.enumerated().map { index, symbol in
            let home = clusterX - 18 - CGFloat(index) * 24
            // The nearest folds first.
            let start = Self.fold + Double(index) * Self.stagger
            let e = Ease.inOut(t, start, start + Self.travel)
            let x = home + (target - home) * CGFloat(e)
            return (symbol, x, 1 - Ease.out(t, start + Self.travel * 0.55, start + Self.travel), 1 - 0.5 * CGFloat(e))
        }
        let lastLanding = Self.fold + Double(count - 1) * Self.stagger + Self.travel
        // The cluster takes a breath each time an icon lands in it.
        var pulse: CGFloat = 0
        for index in 0..<count {
            let landing = Self.fold + Double(index) * Self.stagger + Self.travel
            pulse = max(pulse, CGFloat(Ease.window(t, landing - 0.05, landing + 0.18, rise: 0.05, fall: 0.13)))
        }
        let settle = CGFloat(Ease.spring(t, lastLanding, duration: 0.5))
        let scene = ClutterScene(
            wallpaper: wallpaper, bar: bar, size: size, icons: icons, cluster: clusterLayer, clusterX: clusterX,
            clusterScale: 1 + 0.12 * pulse * (1 - settle) + 0.0, glow: Double(pulse)
        )
        return landingFrame(scene, size: size, scale: scale)
    }
}

private struct ClutterScene: View {
    let wallpaper: LandingWallpaper
    let bar: LandingMenuBar
    let size: CGSize
    let icons: [(symbol: String, x: CGFloat, alpha: Double, scale: CGFloat)]
    let cluster: LandingLayer
    let clusterX: CGFloat
    let clusterScale: CGFloat
    let glow: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The top-right corner of the hero's desktop.
            wallpaper.view.offset(x: size.width - wallpaper.size.width, y: 0)
            bar.view
            ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in
                Image(systemName: icon.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(bar.ink)
                    .frame(width: 22, height: LandingMenuBar.height)
                    .scaleEffect(icon.scale)
                    .opacity(icon.alpha)
                    .offset(x: icon.x - 11, y: 0)
            }
            cluster.view
                .shadow(color: .white.opacity(0.55 * glow), radius: 8)
                .scaleEffect(clusterScale, anchor: .center)
                .offset(x: clusterX, y: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, wallpaper.dark ? .dark : .light)
    }
}

// MARK: - Build: a command's JSON becomes a card

/// A terminal types a CLI command and its JSON comes back; beside it the
/// same numbers arrive as a real BarShelf card, and the few lines of
/// workflow that join the two.
@MainActor
final class LandingBuildPlate: LandingPlate {
    let demo: LandingDemo
    let size = LandingHeroClip.size
    let scale: CGFloat
    let dark = true

    static let duration = 7.0
    static let command = "aas usage --json"
    static let typeFrom = 0.5
    static let typePerChar = 0.055
    static let output = 1.75
    static let card = 2.9
    static let code = 3.9

    static let json = [
        "{",
        "  \"account\": \"june\",",
        "  \"plan\": \"max\",",
        "  \"session\": { \"used\": 0.62, \"resetsIn\": \"1h 48m\" },",
        "  \"week\":    { \"used\": 0.31, \"resetsIn\": \"4d 2h\" }",
        "}",
    ]
    static let workflow = [
        "\"sources\": { \"usage\": {",
        "  \"type\": \"exec\",",
        "  \"command\": [\"aas\", \"usage\", \"--json\"] } }",
    ]

    private var wallpaper: LandingWallpaper!
    private var cardLayer: LandingLayer?

    init(demo: LandingDemo, scale: CGFloat = 3) {
        self.demo = demo
        self.scale = scale
    }

    func prepare() -> Bool {
        guard let wallpaper = LandingWallpaper.make(size: size, dark: dark) else { return false }
        self.wallpaper = wallpaper
        guard let widget = demo.runtime.widgets.first(where: { $0.id == LandingFilm.aasID }) else { return false }
        let host = HostedView(AnyView(
            WidgetCardView(widget: widget, runtime: demo.runtime)
                .padding(Spacing.cardGap)
                .frame(width: RootView.defaultSize.width)
        ), dark: dark)
        cardLayer = host.layer(scale: scale, settle: 0.4)
        return cardLayer != nil
    }

    func frame(at t: Double) -> CGImage? {
        guard let cardLayer else { return nil }
        let typed = Int(max(0, (t - Self.typeFrom) / Self.typePerChar))
        let command = String(Self.command.prefix(typed))
        let typing = typed < Self.command.count
        let caret = typing || Int(t * 2.2) % 2 == 0
        let lines = Self.json.enumerated().map { index, line in
            (line, Ease.out(t, Self.output + Double(index) * 0.07, Self.output + Double(index) * 0.07 + 0.12))
        }
        let scene = BuildScene(
            wallpaper: wallpaper, command: command, caret: caret && t < Self.output, lines: lines,
            card: cardLayer, cardIn: Ease.spring(t, Self.card, duration: 0.55),
            code: Self.workflow, codeIn: Ease.out(t, Self.code, Self.code + 0.4),
            flow: Ease.inOut(t, Self.card - 0.35, Self.card + 0.35)
        )
        return landingFrame(scene, size: size, scale: scale)
    }
}

private struct BuildScene: View {
    let wallpaper: LandingWallpaper
    let command: String
    let caret: Bool
    let lines: [(String, Double)]
    let card: LandingLayer
    let cardIn: Double
    let code: [String]
    let codeIn: Double
    let flow: Double

    private let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    private var terminal: CGRect { CGRect(x: 40, y: 92, width: 410, height: 262) }
    private var cardOrigin: CGPoint { CGPoint(x: 486, y: 72) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper.view
            // The terminal: glass, a title bar, a prompt.
            ZStack(alignment: .topLeading) {
                LandingGlass(wallpaper: wallpaper, frame: terminal, radius: 14, tint: 0.62)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        LandingTrafficLights().scaleEffect(0.85, anchor: .leading)
                        Spacer()
                        Text(verbatim: "zsh").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .frame(height: 26)
                    HStack(spacing: 0) {
                        Text(verbatim: "~ ❯ ").foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.62))
                        Text(verbatim: command).foregroundStyle(.white)
                        Rectangle().fill(Color.white.opacity(caret ? 0.85 : 0)).frame(width: 7, height: 15)
                    }
                    .font(mono)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line.0)
                            .font(mono)
                            .foregroundStyle(Color(red: 0.78, green: 0.8, blue: 0.95))
                            .opacity(line.1)
                            .offset(y: 6 * (1 - line.1))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }
            .frame(width: terminal.width, height: terminal.height, alignment: .topLeading)
            .offset(x: terminal.minX, y: terminal.minY)

            // A spark travelling from the output to the card.
            Circle()
                .fill(RadialGradient(colors: [.white, Color(red: 0.72, green: 0.55, blue: 1).opacity(0)],
                                     center: .center, startRadius: 0, endRadius: 14))
                .frame(width: 28, height: 28)
                .position(x: terminal.maxX - 20 + (cardOrigin.x + 30 - terminal.maxX + 20) * flow,
                          y: terminal.minY + 120 - 40 * sin(flow * .pi))
                .opacity(sin(flow * .pi))

            // The card, on popup glass.
            let frame = CGRect(origin: cardOrigin, size: card.size)
            ZStack(alignment: .topLeading) {
                LandingGlass(wallpaper: wallpaper, frame: frame)
                card.view
            }
            .scaleEffect(0.86 + 0.14 * cardIn, anchor: .topLeading)
            .opacity(min(cardIn * 1.6, 1))
            .offset(x: frame.minX, y: frame.minY)

            // The workflow lines that join them.
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "workflow.json").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                ForEach(Array(code.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .opacity(codeIn)
            .offset(x: terminal.minX, y: terminal.maxY + 22 + 10 * (1 - codeIn))
        }
        .frame(width: wallpaper.size.width, height: wallpaper.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Places: desktop widgets and the dock

/// Widgets on the desktop, and the real BarShelf Dock at the bottom, which
/// switches profiles from Work to Home halfway through.
@MainActor
final class LandingPlacesPlate: LandingPlate {
    let demo: LandingDemo
    let size = LandingHeroClip.size
    let scale: CGFloat
    let dark: Bool

    static let duration = 6.5
    static let tiles = 0.3
    static let switchAt = 3.4

    private var wallpaper: LandingWallpaper!
    private var tiles: [LandingLayer] = []
    private var docks: [LandingLayer] = []
    private let running = RunningApps()

    init(demo: LandingDemo, dark: Bool = false, scale: CGFloat = 3) {
        self.demo = demo
        self.dark = dark
        self.scale = scale
    }

    /// Profiles of apps every Mac has, and a folder.
    private static func profile(_ name: String, symbol: String, apps: [String], folder: String) -> DockProfile {
        var items = apps.map { DockItem(kind: .app(path: $0)) }
        items.append(DockItem(kind: .separator))
        items.append(DockItem(kind: .folder(path: folder, color: nil, label: nil)))
        return DockProfile(name: name, symbol: symbol, items: items)
    }

    func prepare() -> Bool {
        guard let wallpaper = LandingWallpaper.make(size: size, dark: dark) else { return false }
        self.wallpaper = wallpaper
        // Desktop widgets: the real cards, as the desktop shows them.
        for id in [LandingDemo.ID.weather, LandingDemo.ID.battery, LandingDemo.ID.today] {
            guard let widget = demo.widget(id) else { return false }
            let host = HostedView(AnyView(
                WidgetCardView(widget: widget, runtime: demo.runtime)
                    .frame(width: id == LandingDemo.ID.today ? 306 : 146)
            ), dark: dark)
            guard let layer = host.layer(scale: scale, settle: 0.3) else { return false }
            tiles.append(layer)
        }
        // Two dock profiles, each read from a file in the scratch home:
        // nothing here edits a dock, BarShelf's or Apple's.
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else { return false }
        let profiles = [
            Self.profile("Work", symbol: "briefcase", apps: [
                "/System/Applications/Mail.app", "/System/Applications/Calendar.app",
                "/System/Applications/Notes.app", "/System/Applications/Reminders.app",
                "/System/Applications/Utilities/Terminal.app",
            ], folder: "/Applications"),
            Self.profile("Home", symbol: "house", apps: [
                "/System/Applications/Music.app", "/System/Applications/Photos.app",
                "/System/Applications/Maps.app", "/System/Applications/TV.app",
                "/System/Applications/Podcasts.app",
            ], folder: "/System/Applications"),
        ]
        for (index, profile) in profiles.enumerated() {
            let url = URL(fileURLWithPath: home).appendingPathComponent("landing-dock-\(index).json")
            let config = DockConfiguration(
                mode: .alongside, style: .classic, tileSize: 46, magnification: false,
                showRunningApps: false, showTrash: false, profiles: [profile], activeProfileID: profile.id
            )
            try? config.save(to: url)
            let store = DockStore(fileURL: url, appleDock: AppleDock(restart: {}), persistConfiguration: { _, _ in })
            let host = HostedView(AnyView(
                DockView(store: store, runtime: demo.runtime, running: running, limits: DockLayoutLimits(),
                         onHoverChange: { _ in }, onOpenSettings: {})
                    .fixedSize()
            ), dark: dark)
            guard let layer = host.layer(scale: scale, settle: 0.6) else { return false }
            docks.append(layer)
        }
        return true
    }

    func frame(at t: Double) -> CGImage? {
        let tileIn = (0..<tiles.count).map { Ease.spring(t, Self.tiles + Double($0) * 0.22, duration: 0.6) }
        let swap = Ease.inOut(t, Self.switchAt, Self.switchAt + 0.5)
        let scene = PlacesScene(
            wallpaper: wallpaper, tiles: tiles, tileIn: tileIn, docks: docks, swap: swap,
            dockIn: Ease.spring(t, 0.1, duration: 0.6),
            badge: Ease.window(t, Self.switchAt - 0.35, Self.switchAt + 1.2, rise: 0.2, fall: 0.3)
        )
        return landingFrame(scene, size: size, scale: scale)
    }
}

private struct PlacesScene: View {
    let wallpaper: LandingWallpaper
    let tiles: [LandingLayer]
    let tileIn: [Double]
    let docks: [LandingLayer]
    let swap: Double
    let dockIn: Double
    let badge: Double

    var body: some View {
        let width = wallpaper.size.width, height = wallpaper.size.height
        ZStack(alignment: .topLeading) {
            wallpaper.view
            LandingMenuBar(width: width, dark: wallpaper.dark).view
            // Desktop widgets down the right, as macOS places them.
            let rowTwo = 54 + max(tiles.first?.size.height ?? 140, tiles.dropFirst().first?.size.height ?? 140) + 14
            let origins = [CGPoint(x: width - 346, y: 54), CGPoint(x: width - 186, y: 54), CGPoint(x: width - 346, y: rowTwo)]
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                let frame = CGRect(origin: origins[index], size: tile.size)
                ZStack(alignment: .topLeading) {
                    LandingGlass(wallpaper: wallpaper, frame: frame, radius: Radius.card + 4)
                    tile.view.clipShape(RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous))
                }
                .scaleEffect(0.8 + 0.2 * tileIn[index])
                .opacity(min(tileIn[index] * 1.5, 1))
                .offset(x: frame.minX, y: frame.minY)
            }
            // The dock: Work, then Home sliding up in its place.
            ForEach(Array(docks.enumerated()), id: \.offset) { index, dock in
                let shown = index == 0 ? 1 - swap : swap
                let frame = CGRect(x: (width - dock.size.width) / 2, y: height - dock.size.height - 10,
                                   width: dock.size.width, height: dock.size.height)
                ZStack(alignment: .topLeading) {
                    LandingGlass(wallpaper: wallpaper, frame: frame, radius: 20)
                    dock.view
                }
                .opacity(shown * dockIn)
                .offset(x: frame.minX, y: frame.minY + 26 * (index == 0 ? swap : 1 - swap) + 40 * (1 - dockIn))
            }
            // The profile's name, as the switch announces it.
            HStack(spacing: 8) {
                Image(systemName: swap < 0.5 ? "briefcase.fill" : "house.fill")
                Text(verbatim: swap < 0.5 ? "Work" : "Home")
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(wallpaper.dark ? Color.white : Color.black.opacity(0.8))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(LandingGlassCapsule(dark: wallpaper.dark))
            .opacity(badge)
            .position(x: width / 2, y: height - 112)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, wallpaper.dark ? .dark : .light)
    }
}

// MARK: - Trust: asked, flagged, recorded

/// Three beats of the permission model: a widget's card asks before it
/// runs, the menu bar's red dot says something waits, and the audit log
/// keeps the record.
@MainActor
final class LandingTrustPlate: LandingPlate {
    let demo: LandingDemo
    let size = LandingHeroClip.size
    let scale: CGFloat
    let dark = true

    static let duration = 4.2

    private var wallpaper: LandingWallpaper!
    private var approval: LandingLayer?
    private var icon: CGImage?

    init(demo: LandingDemo, scale: CGFloat = 3) {
        self.demo = demo
        self.scale = scale
    }

    func prepare() -> Bool {
        guard let wallpaper = LandingWallpaper.make(size: size, dark: dark) else { return false }
        self.wallpaper = wallpaper
        // The real permission card, filled as Keep Awake's would be.
        let host = HostedView(AnyView(
            PermissionApprovalView(widgetName: "Keep Awake", requests: [
                PermissionRequest(symbol: "terminal", description: "Run osascript -l JavaScript ./keep-awake.js"),
                PermissionRequest(symbol: "folder", description: "Read ~/Library/Application Support/PowerDisplayGuard"),
            ], onAllow: {}, onDeny: {})
                .padding(Spacing.cardInset)
                .frame(width: 330)
        ), dark: dark)
        approval = host.layer(scale: scale, settle: 0.3)
        // The status item with its attention dot, drawn as the menu bar would.
        let badged = BarShelfStatusIcon.badgedImage(BarShelfStatusIcon.logoImage())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(24 * scale * 2), pixelsHigh: Int(18 * scale * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 24, height: 18)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            badged.draw(in: NSRect(x: 0, y: 0, width: 24, height: 18))
            NSGraphicsContext.restoreGraphicsState()
        }
        icon = rep.cgImage
        return approval != nil && icon != nil
    }

    static let log: [(String, String, String)] = [
        ("16:48:02", "permission.approved", "dev.barshelf.keep-awake"),
        ("16:48:03", "exec.run", "/usr/bin/osascript -l JavaScript …"),
        ("16:48:05", "file.read", "PowerDisplayGuard/status.json"),
        ("16:52:11", "permission.narrowed", "dev.barshelf.keep-awake"),
    ]

    func frame(at t: Double) -> CGImage? {
        guard let approval, let icon else { return nil }
        let scene = TrustScene(
            wallpaper: wallpaper, approval: approval, icon: icon,
            cardIn: Ease.spring(t, 0.15, duration: 0.5),
            allow: Ease.window(t, 1.05, 1.35, rise: 0.08, fall: 0.2),
            dotIn: Ease.spring(t, 1.35, duration: 0.5),
            rows: Self.log.indices.map { Ease.out(t, 2.3 + Double($0) * 0.22, 2.3 + Double($0) * 0.22 + 0.25) }
        )
        return landingFrame(scene, size: size, scale: scale)
    }
}

private struct TrustScene: View {
    let wallpaper: LandingWallpaper
    let approval: LandingLayer
    let icon: CGImage
    let cardIn: Double
    let allow: Double
    let dotIn: Double
    let rows: [Double]

    var body: some View {
        let width = wallpaper.size.width
        ZStack(alignment: .topLeading) {
            wallpaper.view
            // 1. The card asks.
            let card = CGRect(origin: CGPoint(x: 40, y: 64), size: approval.size)
            ZStack(alignment: .topLeading) {
                LandingGlass(wallpaper: wallpaper, frame: card, radius: Radius.card + 6)
                approval.view
                // Allow, pressed.
                Capsule().fill(Color.white.opacity(0.25 * allow))
                    .frame(width: 70, height: 26)
                    .offset(x: card.width - 92, y: card.height - 42)
            }
            .scaleEffect((0.9 + 0.1 * cardIn) * 1.32, anchor: .topLeading)
            .opacity(min(cardIn * 1.5, 1))
            .offset(x: card.minX, y: card.minY)

            // 2. The menu bar flags it.
            ZStack {
                Circle().fill(Color.white.opacity(0.08)).frame(width: 128, height: 128)
                Image(decorative: icon, scale: 1).resizable().interpolation(.high).frame(width: 72, height: 54)
            }
            .scaleEffect(0.6 + 0.4 * dotIn)
            .opacity(min(dotIn * 1.4, 1))
            .position(x: width - 150, y: 140)

            // 3. The audit log keeps it.
            VStack(alignment: .leading, spacing: 7) {
                Text(verbatim: "Audit log").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                ForEach(Array(LandingTrustPlate.log.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        Text(verbatim: row.0).foregroundStyle(.white.opacity(0.45))
                        Text(verbatim: row.1).foregroundStyle(row.1.hasPrefix("permission") ? Color(red: 0.72, green: 0.6, blue: 1) : .white)
                        Text(verbatim: row.2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .opacity(rows[index])
                    .offset(x: 14 * (1 - rows[index]))
                }
            }
            .padding(16)
            .frame(width: 430, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
            .opacity(rows.first ?? 0)
            .offset(x: width - 470, y: 296)
        }
        .frame(width: wallpaper.size.width, height: wallpaper.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}
