import AppKit
import MenubucketCore
import SwiftUI

/// Headless screenshot generator: `barshelf screenshot <dir>` renders the
/// *actual* SwiftUI widget UI (real `ViewTreeRenderer`, real adapters) to PNGs
/// offscreen via `ImageRenderer` — no menu bar, no Screen Recording permission.
/// Widget previews for the README and the registry. The landing page's
/// videos and stills come from `barshelf-app landing-media`
/// (`LandingMediaMode`), which records the real popup and cards.
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
        ok = render(ClusterShot(scheme: .dark), name: "menubar-cluster-dark", to: dir) && ok
        ok = render(ClusterShot(scheme: .light), name: "menubar-cluster-light", to: dir) && ok
        // Standalone widget-card tiles for the landing-page preview gallery
        // (light — the landing page is a fixed light theme).
        let tiles: [(name: String, title: String, icon: String, node: UINode, accent: String?)] = [
            ("tile-today", "Today", "calendar", ShotData.todayNode, "red"),
            ("tile-weather", "Weather", "cloud.sun.fill", ShotData.weatherNode, "blue"),
            ("tile-battery", "Battery", "battery.100percent", ShotData.batteryNode, "green"),
            ("tile-otp", "OTP Codes", "key.fill", ShotData.otpNode, "purple"),
            ("tile-files", "Recent Files", "clock.arrow.circlepath", ShotData.filesNode, nil),
            ("tile-aas", "aas usage", "gauge", ShotData.aasNode, "orange"),
            ("tile-tend-watch", "tend Watch", "rectangle.3.group.bubble.left.fill", ShotData.tendWatchNode, "purple"),
            ("tile-k8s", "k8s pods", "shippingbox", ShotData.k8sNode, nil),
            ("tile-next-meeting", "Next Meeting", "calendar.badge.clock", ShotData.nextMeetingNode, "blue"),
            ("tile-quick-shelf", "Quick Shelf", "square.grid.2x2", ShotData.quickShelfNode, "purple"),
            ("tile-project-status", "Project Status", "point.3.connected.trianglepath.dotted", ShotData.projectStatusNode, "purple"),
            ("tile-focus-timer", "Focus Timer", "timer", ShotData.focusTimerNode, "orange"),
            ("tile-clipboard-shelf", "Clipboard Shelf", "doc.on.clipboard", ShotData.clipboardShelfNode, "purple"),
            ("tile-developer-inbox", "Developer Inbox", "tray.full", ShotData.developerInboxNode, "blue"),
            ("tile-system", "System", "cpu.fill", ShotData.systemNode, "purple"),
            ("tile-sensors", "Sensors", "thermometer.medium", ShotData.sensorsNode, "orange"),
            ("tile-battery-meter", "Battery", "battery.100percent", ShotData.batteryMeterRenderNode, "green"),
            ("tile-clock", "Clock", "clock.fill", ShotData.clockRenderNode, "blue"),
            ("tile-calendar", "Calendar", "calendar", ShotData.calendarRenderNode, "red"),
            ("tile-codex-reset", "Codex Reset", "cloud.sun.fill", ShotData.codexResetRenderNode, "orange"),
            ("tile-downloads-new", "Downloads", "arrow.down.circle.fill", ShotData.downloadsNewRenderNode, "green"),
            ("tile-exchange", "Exchange", "dollarsign.circle.fill", ShotData.exchangeRenderNode, "green"),
            ("tile-github-status", "GitHub Status", "checkmark.seal.fill", ShotData.githubStatusRenderNode, "green"),
            ("tile-network", "Network", "arrow.up.arrow.down.circle.fill", ShotData.networkRenderNode, "blue"),
            ("tile-now-playing", "Now Playing", "music.note", ShotData.nowPlayingRenderNode, "pink"),
            ("tile-reminders", "Reminders", "checklist", ShotData.remindersRenderNode, "orange"),
            ("tile-stock", "Stock", "chart.line.uptrend.xyaxis", ShotData.stockRenderNode, "green"),
        ]
        for tile in tiles {
            ok = render(
                TileShot(title: tile.title, icon: tile.icon, node: tile.node, accentName: tile.accent),
                name: tile.name,
                to: dir
            ) && ok
        }
        ok = renderGallery(dir: dir) && ok
        return ok ? 0 : 1
    }

    /// Renders the gallery shelves (bundled registry, no network) — used to
    /// eyeball the shelf layout and as a marketing/README asset. Uses the
    /// real `GalleryCard`, but in a non-lazy composition: `ImageRenderer`
    /// cannot rasterize native controls (TextField/Picker) or lazy grids.
    @MainActor
    private static func renderGallery(dir: URL) -> Bool {
        let model = GalleryModel()
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("registry/index.json"))
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("registry/index.json"))
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
              let parsed = try? RegistryIndex.parse(data).index
        else {
            FileHandle.standardError.write(Data("gallery registry load failed\n".utf8))
            return false
        }
        // ImageRenderer captures synchronously and cannot wait for AsyncImage.
        // Omit remote art so marketing generation is deterministic and never
        // records loading/error placeholders as product UI.
        let deterministic = parsed.widgets.map { entry -> RegistryWidgetEntry in
            var copy = entry
            copy.screenshot = nil
            copy.readme = nil
            return copy
        }
        model.setEntries(forPreview: deterministic)
        let view = GalleryShot(sections: model.sections)
            .environment(\.colorScheme, .light)
        guard render(view, name: "gallery", to: dir) else { return false }
        // The detail page for a widget with permissions and a requirement.
        guard let detail = deterministic.first(where: {
            $0.requires != nil && $0.permissions?.exec?.isEmpty == false
        }) ?? deterministic.first else { return false }
        let detailView = GalleryDetailView(entry: detail, model: model, scrolls: false)
            .frame(width: 720)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        return render(detailView, name: "gallery-detail", to: dir)
    }

    @MainActor
    private static func render<V: View>(_ view: V, name: String, to dir: URL) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.widgetStillRender, true))
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

enum ShotData {
    /// Real `tend Watch` output — the widget's own `load()` run against the
    /// isolated demo fleet from tend's `docs/demo-setup.sh` (no live sessions),
    /// with the relative ages varied so the tile doesn't read as one instant.
    static var tendWatchNode: UINode {
        let json = """
        {"spacing":8,"type":"vstack","children":[
          {"id":"local-agent-0","spacing":8,"alignment":"baseline","type":"hstack","children":[
            {"size":8,"tint":"warning","accessibilityLabel":"Choose","type":"image","source":{"kind":"sfSymbol","name":"circle.fill"}},
            {"spacing":1,"widthFill":true,"type":"vstack","children":[
              {"spacing":8,"type":"hstack","children":[
                {"role":"body","lineLimit":1,"widthFill":true,"type":"text","text":"auth:0.0"},
                {"role":"caption","foreground":"tertiary","monospacedDigit":true,"lineLimit":1,"type":"text","text":"8s"}]},
              {"role":"caption","foreground":"warning","lineLimit":1,"type":"text","text":"Choose · rotate the JWT signing keys across environments"}]}]},
          {"id":"local-agent-1","spacing":8,"alignment":"baseline","type":"hstack","children":[
            {"size":8,"tint":"warning","accessibilityLabel":"Needs input","type":"image","source":{"kind":"sfSymbol","name":"circle.fill"}},
            {"spacing":1,"widthFill":true,"type":"vstack","children":[
              {"spacing":8,"type":"hstack","children":[
                {"role":"body","lineLimit":1,"widthFill":true,"type":"text","text":"web:0.0"},
                {"role":"caption","foreground":"tertiary","monospacedDigit":true,"lineLimit":1,"type":"text","text":"1m"}]},
              {"role":"caption","foreground":"warning","lineLimit":1,"type":"text","text":"Needs input · fix the SSE reconnect backoff"}]}]},
          {"id":"local-agent-2","spacing":8,"alignment":"baseline","type":"hstack","children":[
            {"size":8,"tint":"warning","accessibilityLabel":"Needs input","type":"image","source":{"kind":"sfSymbol","name":"circle.fill"}},
            {"spacing":1,"widthFill":true,"type":"vstack","children":[
              {"spacing":8,"type":"hstack","children":[
                {"role":"body","lineLimit":1,"widthFill":true,"type":"text","text":"main:1.0"},
                {"role":"caption","foreground":"tertiary","monospacedDigit":true,"lineLimit":1,"type":"text","text":"6m"}]},
              {"role":"caption","foreground":"warning","lineLimit":1,"type":"text","text":"Needs input · audit the legacy auth middleware for token handling — flag anything that st…"}]}]},
          {"id":"local-agent-3","spacing":8,"alignment":"baseline","type":"hstack","children":[
            {"size":8,"tint":"good","accessibilityLabel":"Working","type":"image","source":{"kind":"sfSymbol","name":"circle.fill"}},
            {"spacing":1,"widthFill":true,"type":"vstack","children":[
              {"spacing":8,"type":"hstack","children":[
                {"role":"body","lineLimit":1,"widthFill":true,"type":"text","text":"infra:0.0"},
                {"role":"caption","foreground":"tertiary","monospacedDigit":true,"lineLimit":1,"type":"text","text":"22s"}]},
              {"role":"caption","foreground":"secondary","lineLimit":1,"type":"text","text":"Codex · terraform: split the network module and pin providers"}]}]},
          {"id":"local-agent-4","spacing":8,"alignment":"baseline","type":"hstack","children":[
            {"size":8,"tint":"good","accessibilityLabel":"Working","type":"image","source":{"kind":"sfSymbol","name":"circle.fill"}},
            {"spacing":1,"widthFill":true,"type":"vstack","children":[
              {"spacing":8,"type":"hstack","children":[
                {"role":"body","lineLimit":1,"widthFill":true,"type":"text","text":"api:0.0"},
                {"role":"caption","foreground":"accent","monospacedDigit":true,"lineLimit":1,"type":"text","text":"◇2"},
                {"role":"caption","foreground":"tertiary","monospacedDigit":true,"lineLimit":1,"type":"text","text":"3m"}]},
              {"role":"caption","foreground":"secondary","lineLimit":1,"type":"text","text":"Claude Code · port the reconciler onto the new PaneBackend trait"},
              {"id":"local-agent-4-sub-0","spacing":4,"type":"hstack","children":[
                {"role":"caption","foreground":"tertiary","type":"text","text":"├─"},
                {"role":"caption","foreground":"secondary","lineLimit":1,"widthFill":true,"type":"text","text":"Explore · map the reconcile call sites"}]},
              {"id":"local-agent-4-sub-1","spacing":4,"type":"hstack","children":[
                {"role":"caption","foreground":"tertiary","type":"text","text":"└─"},
                {"role":"caption","foreground":"secondary","lineLimit":1,"widthFill":true,"type":"text","text":"general-purpose · port and de-dup"}]}]}]},
          {"type":"hstack","children":[
            {"type":"spacer"},
            {"role":"caption","foreground":"tertiary","type":"text","text":"+3 more"}]}]}
        """
        return (try? JSONDecoder().decode(UINode.self, from: Data(json.utf8))) ?? UINode(type: "spacer")
    }

    /// Real `AasUsageAdapter` output from representative JSON.
    static var aasNode: UINode {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let reset5h = now + 2 * 3_600_000 + 10 * 60_000
        let reset7d = now + 3 * 86_400_000 + 9 * 3_600_000
        let json = """
        {"accounts":[
          {"provider":"claude","name":"work-01","email":null,"active":true,"plan":"max","planLabel":"Max 20x","headline":"","error":null,"meters":[{"label":"5h","usedPct":64,"resetMs":\(reset5h)},{"label":"7d","usedPct":36,"resetMs":\(reset7d)}]},
          {"provider":"claude","name":"personal","email":null,"active":false,"plan":"pro","planLabel":"Pro","headline":"","error":null,"meters":[{"label":"5h","usedPct":82,"resetMs":\(reset5h)},{"label":"7d","usedPct":58,"resetMs":\(reset7d)}]},
          {"provider":"codex","name":"team-x","email":null,"active":false,"plan":null,"planLabel":null,"headline":"","error":null,"meters":[{"label":"5h","usedPct":94,"resetMs":\(reset5h)},{"label":"7d","usedPct":71,"resetMs":\(reset7d)}]}
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

    /// Real `Battery` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against the exec source on a MacBook at 82%, discharging.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var batteryMeterRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"x-apple.systempreferences:com.apple.Battery-Settings.extension"},"children":[{"children":[{"type":"spacer"},{"foreground":"secondary","lineLimit":1,"role":"caption","text":"discharging","type":"text"}],"spacing":6,"type":"hstack"},{"monospacedDigit":true,"role":"title","size":40,"text":"82%","type":"text"},{"style":"linear","tint":"good","type":"progress","value":0.82}],"spacing":6,"type":"vstack"}
        """#)
    }

    /// Real `Clock` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against this Mac's own `/bin/date` output.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var clockRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"x-apple.systempreferences:com.apple.Date-Time-Settings.extension"},"children":[{"children":[{"monospacedDigit":true,"role":"title","size":44,"text":"22:05","type":"text"},{"foreground":"secondary","monospacedDigit":true,"role":"caption","size":17,"text":"38","type":"text"}],"spacing":3,"type":"hstack"},{"foreground":"secondary","role":"caption","text":"Fri Sep 25","type":"text"}],"spacing":2,"type":"vstack"}
        """#)
    }

    /// Real `Calendar` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against this Mac's own month-grid command output.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var calendarRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openApp","value":"com.apple.iCal"},"children":[{"children":[{"lineLimit":1,"role":"title","text":"September","type":"text"}],"spacing":6,"type":"hstack"},{"children":[{"foreground":"tertiary","role":"caption","text":"Su","type":"text"},{"foreground":"tertiary","role":"caption","text":"Mo","type":"text"},{"foreground":"tertiary","role":"caption","text":"Tu","type":"text"},{"foreground":"tertiary","role":"caption","text":"We","type":"text"},{"foreground":"tertiary","role":"caption","text":"Th","type":"text"},{"foreground":"tertiary","role":"caption","text":"Fr","type":"text"},{"foreground":"tertiary","role":"caption","text":"Sa","type":"text"}],"columns":7,"spacing":2,"type":"grid"},{"columns":7,"items":[{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"1","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"2","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"3","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"4","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"5","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"6","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"7","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"8","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"9","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"10","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"11","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"12","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"13","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"14","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"15","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"16","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"17","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"18","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"19","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"20","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"21","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"22","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"23","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"24","type":"text"},{"fill":"accent","foreground":"primary","monospacedDigit":true,"role":"title","text":"25","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"26","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"27","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"28","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"29","type":"text"},{"fill":"","foreground":"primary","monospacedDigit":true,"role":"body","text":"30","type":"text"}],"spacing":2,"type":"grid"}],"spacing":4,"type":"vstack"}
        """#)
    }

    /// Real `Codex Reset` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a live response from willcodexquotareset.com/api/forecast.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var codexResetRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"https://www.willcodexquotareset.com/"},"children":[{"children":[{"foreground":"secondary","lineLimit":1,"role":"caption","text":"Will Codex reset?","type":"text"},{"type":"spacer"},{"foreground":"secondary","role":"caption","text":"48H","type":"text"}],"spacing":6,"type":"hstack"},{"foreground":"secondary","monospacedDigit":true,"role":"title","size":32,"text":"29%","type":"text"},{"style":"linear","tint":"secondary","type":"progress","value":0.29},{"foreground":"secondary","lineLimit":2,"role":"caption","text":"Last reset 610.4h ago · alert at 70%","type":"text"}],"padding":10,"spacing":6,"type":"vstack"}
        """#)
    }

    /// Real `Downloads` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against 42 files with 39 at the last check.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var downloadsNewRenderNode: UINode {
        decode(#"""
        {"action":{"type":"revealFile","value":"~/Downloads"},"children":[{"children":[{"type":"spacer"},{"foreground":"secondary","monospacedDigit":true,"role":"caption","text":"42 files","type":"text"}],"spacing":7,"type":"hstack"},{"foreground":"good","monospacedDigit":true,"role":"body","text":"+3 since last check","type":"text"}],"spacing":6,"tone":"accent","type":"card"}
        """#)
    }

    /// Real `Exchange` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a live response from open.er-api.com.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var exchangeRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"https://www.xe.com/currencyconverter/"},"children":[{"children":[{"foreground":"secondary","role":"caption","text":"USD → KRW","type":"text"}],"spacing":6,"type":"hstack"},{"monospacedDigit":true,"role":"title","size":32,"text":"₩1369","type":"text"},{"foreground":"secondary","role":"caption","text":"per $1","type":"text"}],"spacing":2,"type":"vstack"}
        """#)
    }

    /// Real `GitHub Status` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a live response from githubstatus.com.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var githubStatusRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"https://www.githubstatus.com"},"children":[{"children":[{"lineLimit":1,"role":"title","text":"GitHub","type":"text"},{"type":"spacer"},{"text":"OK","tint":"good","type":"badge"}],"spacing":8,"type":"hstack"},{"lineLimit":2,"role":"body","text":"All Systems Operational","type":"text"},{"foreground":"secondary","lineLimit":2,"role":"caption","text":"Refreshes on open, every 15 minutes, and when your Mac wakes.","type":"text"}],"padding":10,"spacing":8,"type":"vstack"}
        """#)
    }

    /// Real `Network` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against the system network source with sample rates and a private LAN address.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var networkRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"x-apple.systempreferences:com.apple.Network-Settings.extension"},"children":[{"children":[{"type":"spacer"},{"foreground":"secondary","monospacedDigit":true,"role":"caption","text":"All interfaces","type":"text"}],"spacing":6,"type":"hstack"},{"lineLimit":1,"monospacedDigit":true,"role":"title","size":18,"text":"192.168.0.8","type":"text"},{"children":[{"children":[{"size":11,"source":{"kind":"sfSymbol","name":"arrow.down"},"tint":"accent","type":"image"},{"monospacedDigit":true,"role":"caption","text":"1.3 MB/s","type":"text"}],"spacing":4,"type":"hstack"},{"children":[{"size":11,"source":{"kind":"sfSymbol","name":"arrow.up"},"tint":"warning","type":"image"},{"monospacedDigit":true,"role":"caption","text":"86 KB/s","type":"text"}],"spacing":4,"type":"hstack"}],"spacing":12,"type":"hstack"}],"spacing":8,"type":"vstack"}
        """#)
    }

    /// Real `Now Playing` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a sample track (the real source reads Music or Spotify).
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var nowPlayingRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openApp","value":"com.apple.Music"},"children":[{"lineLimit":2,"role":"title","text":"Clair de Lune - Claude Debussy","type":"text"}],"spacing":4,"type":"vstack"}
        """#)
    }

    /// Real `Reminders` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a sample count of 3 (the real source reads Reminders).
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var remindersRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openApp","value":"com.apple.reminders"},"children":[{"monospacedDigit":true,"role":"title","size":40,"text":"3","type":"text"},{"foreground":"secondary","role":"caption","text":"open","type":"text"}],"spacing":2,"type":"vstack"}
        """#)
    }

    /// Real `Stock` render: the widget's own `workflow.json` evaluated
    /// by `WorkflowEngine` against a live Yahoo Finance quote for the default AAPL symbol.
    /// The inner header's glyph and title are dropped: the tile header carries them.
    static var stockRenderNode: UINode {
        decode(#"""
        {"action":{"type":"openURL","url":"https://finance.yahoo.com/quote/AAPL"},"children":[{"children":[{"foreground":"secondary","role":"caption","text":"AAPL","type":"text"}],"spacing":6,"type":"hstack"},{"monospacedDigit":true,"role":"title","size":32,"text":"335.92","type":"text"},{"foreground":"danger","monospacedDigit":true,"role":"caption","text":"▼ -1.1","type":"text"}],"spacing":2,"type":"vstack"}
        """#)
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

    /// The `system` widget's three meters. Fixed values keep the marketing
    /// asset deterministic — the live widget reads the running machine.
    static var systemNode: UINode {
        // No inner "System" caption — the card header already names the widget.
        decode("""
        {"type":"vstack","spacing":10,"children":[
          {"type":"vstack","spacing":3,"children":[
            {"type":"hstack","children":[
              {"type":"text","text":"CPU","role":"caption"},
              {"type":"spacer"},
              {"type":"text","text":"21%","role":"caption","monospacedDigit":true,"foreground":"good"}]},
            {"type":"progress","style":"linear","value":0.21,"tint":"good"}]},
          {"type":"vstack","spacing":3,"children":[
            {"type":"hstack","children":[
              {"type":"text","text":"Memory","role":"caption"},
              {"type":"spacer"},
              {"type":"text","text":"63%","role":"caption","monospacedDigit":true,"foreground":"good"}]},
            {"type":"progress","style":"linear","value":0.63,"tint":"good"}]},
          {"type":"vstack","spacing":3,"children":[
            {"type":"hstack","children":[
              {"type":"text","text":"Disk","role":"caption"},
              {"type":"spacer"},
              {"type":"text","text":"14%","role":"caption","monospacedDigit":true,"foreground":"good"}]},
            {"type":"progress","style":"linear","value":0.14,"tint":"good"}]}]}
        """)
    }

    /// The `sensors` widget on a Mac that reports fans. A fanless Mac shows
    /// "Fans — none" instead; the tile picks the richer case.
    static var sensorsNode: UINode {
        decode("""
        {"type":"vstack","spacing":8,"children":[
          {"type":"vstack","spacing":3,"children":[
            {"type":"hstack","children":[
              {"type":"text","text":"CPU","role":"caption"},
              {"type":"spacer"},
              {"type":"text","text":"45.8 °C","role":"caption","monospacedDigit":true,"foreground":"good"}]},
            {"type":"progress","style":"linear","value":0.458,"tint":"good"}]},
          {"type":"hstack","children":[
            {"type":"text","text":"GPU","role":"caption"},
            {"type":"spacer"},
            {"type":"text","text":"42.8 °C","role":"caption","monospacedDigit":true,"foreground":"secondary"}]},
          {"type":"hstack","children":[
            {"type":"text","text":"Battery","role":"caption"},
            {"type":"spacer"},
            {"type":"text","text":"29.1 °C","role":"caption","monospacedDigit":true,"foreground":"secondary"}]},
          {"type":"hstack","children":[
            {"type":"text","text":"Fan 1","role":"caption"},
            {"type":"spacer"},
            {"type":"text","text":"2100 rpm","role":"caption","monospacedDigit":true,"foreground":"secondary"}]}]}
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

    static var nextMeetingNode: UINode {
        decode("""
        {"type":"vstack","spacing":7,"children":[
          {"type":"hstack","spacing":6,"children":[
            {"type":"badge","text":"IN 18 MIN","tone":"accent"},{"type":"spacer"},
            {"type":"text","text":"10:30–11:00","role":"caption","foreground":"secondary"}]},
          {"type":"text","text":"Product weekly sync","role":"title","lineLimit":2},
          {"type":"hstack","spacing":6,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"video.fill"},"size":12,"tint":"accent"},
            {"type":"text","text":"Join Google Meet","role":"caption","foreground":"accent"}]}]}
        """)
    }

    static var quickShelfNode: UINode {
        decode("""
        {"type":"vstack","spacing":7,"children":[
          {"type":"hstack","spacing":7,"children":[
            {"type":"button","title":"Finder","icon":"folder.fill"},
            {"type":"button","title":"Notes","icon":"note.text"}]},
          {"type":"hstack","spacing":7,"children":[
            {"type":"button","title":"Terminal","icon":"terminal.fill"},
            {"type":"button","title":"GitHub","icon":"chevron.left.forwardslash.chevron.right"}]},
          {"type":"text","text":"Apps, folders and links — one click away","role":"caption","foreground":"secondary"}]}
        """)
    }

    static var projectStatusNode: UINode {
        decode("""
        {"type":"vstack","spacing":7,"children":[
          {"type":"hstack","spacing":6,"children":[
            {"type":"text","text":"barshelf","role":"title"},{"type":"spacer"},{"type":"badge","text":"main","tone":"accent"}]},
          {"type":"hstack","spacing":7,"children":[
            {"type":"badge","text":"3 modified","tone":"warning"},
            {"type":"badge","text":"↑2 ↓0","tone":"good"}]},
          {"type":"text","text":"feat: add useful starter widgets","role":"caption","foreground":"secondary","lineLimit":1}]}
        """)
    }

    static var focusTimerNode: UINode {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return decode("""
        {"type":"hstack","spacing":12,"children":[
          {"type":"progress","style":"ring","countdown":{"from":\(now),"until":\(now + 1_125_000)},"size":52,"tint":"accent"},
          {"type":"vstack","spacing":5,"widthFill":true,"children":[
            {"type":"text","text":"18:45","size":30,"role":"title","monospacedDigit":true},
            {"type":"text","text":"Deep work · session 3","role":"caption","foreground":"secondary"},
            {"type":"hstack","spacing":6,"children":[{"type":"button","title":"Pause","icon":"pause.fill"},{"type":"button","title":"Reset","icon":"arrow.counterclockwise"}]}]}]}
        """)
    }

    static var clipboardShelfNode: UINode {
        decode("""
        {"type":"list","spacing":4,"items":[
          {"type":"hstack","id":"clip-1","spacing":7,"children":[{"type":"image","source":{"kind":"sfSymbol","name":"link"},"size":13,"tint":"accent"},{"type":"text","text":"https://github.com/Open330/barshelf","role":"body","lineLimit":1}]},
          {"type":"hstack","id":"clip-2","spacing":7,"children":[{"type":"image","source":{"kind":"sfSymbol","name":"text.alignleft"},"size":13,"tint":"secondary"},{"type":"text","text":"Ship the small useful thing first.","role":"body","lineLimit":1}]},
          {"type":"hstack","id":"clip-3","spacing":7,"children":[{"type":"image","source":{"kind":"sfSymbol","name":"doc.on.doc"},"size":13,"tint":"secondary"},{"type":"text","text":"swift test --filter RegistryTests","role":"code","lineLimit":1}]}]}
        """)
    }

    static var developerInboxNode: UINode {
        decode("""
        {"type":"vstack","spacing":7,"children":[
          {"type":"hstack","spacing":7,"children":[{"type":"badge","text":"2 reviews","tone":"warning"},{"type":"badge","text":"1 failed","tone":"danger"},{"type":"spacer"},{"type":"text","text":"GitHub","role":"caption","foreground":"secondary"}]},
          {"type":"list","spacing":4,"items":[
            {"type":"hstack","id":"pr-1","spacing":6,"children":[{"type":"image","source":{"kind":"sfSymbol","name":"arrow.triangle.pull"},"size":12,"tint":"warning"},{"type":"text","text":"#128 Review registry previews","lineLimit":1}]},
            {"type":"hstack","id":"pr-2","spacing":6,"children":[{"type":"image","source":{"kind":"sfSymbol","name":"xmark.circle.fill"},"size":12,"tint":"danger"},{"type":"text","text":"#126 macOS CI failed","lineLimit":1}]}]}]}
        """)
    }
}

// MARK: - Popover composition (mirrors the real RootView chrome)

private struct ShotCard: View {
    let title: String
    let icon: String
    let node: UINode
    var accentName: String? = nil

    private var accent: Color { WidgetAppearance(accent: accentName).accentColor ?? .accentColor }

    /// The real card: icon tile and name, the widget below, on a soft card.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.stack) {
                CardIconTile(symbol: icon, color: accent)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            ViewTreeRenderer(node: node)
                .environment(\.widgetAppearance, WidgetAppearance(accent: accentName))
        }
        .padding(Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Fill.card))
    }
}

/// RootView's chrome without native menus (ImageRenderer cannot draw them):
/// page name and position, refresh and ⋯, the search capsule.
private struct ShotHeader: View {
    let page: String
    var position: String?

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.stack) {
                Text(page).font(.headline)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if let position {
                    Text(position).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
                    .frame(width: ControlMetrics.height, height: ControlMetrics.height)
            }
            HStack(spacing: Spacing.stack) {
                Image(systemName: "magnifyingglass").font(.callout.weight(.medium))
                Text("Search widgets").font(.callout)
                Spacer(minLength: 0)
                KeyCap("⌘F")
            }
            .foregroundStyle(.secondary)
            .padding(.leading, Spacing.s - Spacing.hair)
            .padding(.trailing, Spacing.stack)
            .frame(height: ControlMetrics.height)
            .background(Capsule().fill(Fill.hover))
        }
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xs)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.xxs)
    }
}

/// The page dots under the shelf, the current one larger and solid.
private struct ShotDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary
                        : Color.secondary.opacity(RootView.inactivePageDotOpacity(increasedContrast: false)))
                    .frame(
                        width: RootView.pageDotDiameter(isCurrent: index == current, isDropTarget: false),
                        height: RootView.pageDotDiameter(isCurrent: index == current, isDropTarget: false)
                    )
                    .frame(width: Spacing.l, height: Spacing.l)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.stack)
    }
}

// MARK: - Gallery composition (non-lazy, ImageRenderer-safe)

private struct GalleryShot: View {
    let sections: [GalleryModel.GallerySection]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(section.title)
                            .font(.headline)
                        Text("\(section.entries.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, -4)
                    ForEach(pairs(section.entries), id: \.self.first?.id) { pair in
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(pair, id: \.id) { entry in
                                GalleryCard(
                                    entry: entry,
                                    isInstalled: false,
                                    updateAvailable: false,
                                    requirementStatus: .satisfied,
                                    install: {}
                                )
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            if pair.count == 1 {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pairs(_ entries: [RegistryWidgetEntry]) -> [[RegistryWidgetEntry]] {
        stride(from: 0, to: entries.count, by: 2).map { start in
            Array(entries[start..<min(start + 2, entries.count)])
        }
    }
}

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
            ShotHeader(page: "Demo", position: "1/3")
            VStack(spacing: Spacing.cardGap) {
                ShotCard(title: "Today", icon: "calendar", node: ShotData.todayNode, accentName: "red")
                HStack(alignment: .top, spacing: Spacing.cardGap) {
                    ShotCard(title: "Battery", icon: "battery.100percent", node: ShotData.batteryNode, accentName: "green")
                    ShotCard(title: "Weather", icon: "cloud.sun.fill", node: ShotData.weatherNode, accentName: "blue")
                }
                ShotCard(title: "aas usage", icon: "gauge", node: ShotData.aasNode, accentName: "orange")
            }
            .padding(Spacing.cardGap)
            ShotDots(count: 3, current: 0)
        }
        .frame(width: RootView.defaultSize.width)
        // ImageRenderer draws no materials; the popup's solid stand-in.
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).strokeBorder(Fill.hairline, lineWidth: 1))
        .padding(20)
        .background(shotBackground)
        .environment(\.colorScheme, scheme)
    }

    private var shotBackground: some View {
        (scheme == .dark ? Color(red: 0.04, green: 0.10, blue: 0.12) : Color(red: 0.93, green: 0.96, blue: 0.95))
    }
}

// MARK: - Menu bar cluster

/// The cluster three ways on a strip of menu bar: folded as the status item
/// draws it, fanned out under the pointer with a chip active, and the peek.
private struct ClusterShot: View {
    let scheme: ColorScheme

    private static let chips: [ClusterChip] = [
        ClusterChip(widgetID: "work", name: "work-01", initial: "W", fraction: 0.36, tint: .good, reading: "36% · 2h 10m", value: "36%"),
        ClusterChip(widgetID: "personal", name: "personal", initial: "P", fraction: 0.18, tint: .warning, reading: "18% · 2h 10m", value: "18%"),
        ClusterChip(widgetID: "teamx", name: "team-x", initial: "T", fraction: 0.06, tint: .danger, alert: true, reading: "6% left", value: "6%"),
        ClusterChip(widgetID: "battery", name: "Battery", symbol: "battery.75percent", initial: "B", fraction: 0.8, tint: .good, reading: "80%"),
        ClusterChip(widgetID: "k8s", name: "k8s pods", symbol: "shippingbox.fill", initial: "K", fraction: 0.92, tint: .warning, reading: "11/12 ready", value: "11/12"),
    ]
    private static let colors: [String: NSColor] = [
        "work": NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        "personal": .systemPurple, "teamx": NSColor(red: 0.06, green: 0.64, blue: 0.5, alpha: 1),
        "battery": .systemGreen, "k8s": .systemBlue,
    ]

    private var barHeight: CGFloat { NSStatusBar.system.thickness }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            bar { folded }
            bar { fanned }
            ClusterPeekView(chip: Self.chips[2], color: Color(nsColor: Self.colors["teamx"]!))
        }
        .padding(Spacing.l)
        .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.9))
        .environment(\.colorScheme, scheme)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            content()
            Text(verbatim: "Thu 9:41").font(.callout.weight(.medium))
        }
        .padding(.horizontal, Spacing.s)
        .frame(width: 420, height: barHeight, alignment: .trailing)
        .background(scheme == .dark ? Color(white: 0.18) : Color(white: 0.97))
    }

    private var folded: some View { stack(focus: nil) }

    /// The pointer on team-x: a gap on each side of it, the chips stepping
    /// into the hidden icon's room, same width.
    private var fanned: some View { stack(focus: 2) }

    private func stack(focus: Int?) -> some View {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let image = MenuBarController.clusterImage(
            Self.chips,
            positions: MenuBarController.clusterTargets(Self.chips, focus: focus),
            focus: focus,
            pill: focus.map { _ in MenuBarController.pillWidth(Self.chips) },
            lead: focus == nil ? 0 : MenuBarController.clusterLead(for: Self.chips),
            markAlpha: focus == nil ? 1 : 0,
            mark: BarShelfStatusIcon.image(for: AppPreferences.defaultMenuBarSymbol, fallback: "tray.full"),
            badged: false,
            color: { [colors = MenuBarController.clusterColors(Self.chips) { Self.colors[$0] ?? .controlAccentColor }] in
                colors[$0.id] ?? .controlAccentColor
            },
            appearance: appearance,
            height: barHeight
        )
        return Image(nsImage: image)
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

    private func stepView(_ num: String, _ label: LocalizedStringKey, done: Bool = false, now: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(num)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 19, height: 19)
                .background(Circle().fill(done ? Color.accentColor : (now ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.2))))
                .foregroundColor(done ? Color(nsColor: .windowBackgroundColor) : (now ? .accentColor : .secondary))
            Text(label).font(.system(size: 12)).foregroundColor(now || done ? .primary : .secondary)
        }
    }

    private func optRow(_ label: LocalizedStringKey, selected: Bool = false) -> some View {
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
