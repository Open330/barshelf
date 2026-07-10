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
        return ok ? 0 : 1
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
        decode("""
        {"type":"vstack","spacing":6,"children":[
          {"type":"hstack","spacing":6,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"battery.100percent"},"size":15,"tint":"good"},
            {"type":"text","text":"Battery","role":"caption","foreground":"secondary","lineLimit":1}]},
          {"type":"text","text":"80%","size":40,"role":"title","monospacedDigit":true},
          {"type":"progress","style":"linear","value":0.8,"tint":"good"}]}
        """)
    }

    static var weatherNode: UINode {
        decode("""
        {"type":"vstack","spacing":2,"children":[
          {"type":"hstack","spacing":6,"children":[
            {"type":"image","source":{"kind":"sfSymbol","name":"cloud.sun.fill"},"size":14,"tint":"accent"},
            {"type":"text","text":"Seoul","role":"caption","foreground":"secondary"}]},
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
