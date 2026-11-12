#if DEBUG
import AppKit
import MenubucketCore
import SwiftUI
@testable import MenubucketApp

/// The landing page's stills: the popup in light and dark, the widget
/// tiles, and the builder in a window, all from the real views on the
/// staged demo shelf.
@MainActor
struct LandingStills {
    let demo: LandingDemo

    /// Tiles for widgets that are not bundled (third-party, or a user's own
    /// script): their manifest in brief, and a render of their output.
    private struct Extra {
        let file: String
        let id: String
        let name: String
        let icon: String
        let accent: String?
        let node: UINode
    }

    func render(to dir: URL) -> Bool {
        let extras = [
            Extra(file: "tile-otp", id: "dev.example.otpeek", name: "OTP Codes", icon: "key.fill",
                  accent: "purple", node: ShotData.otpNode),
            Extra(file: "tile-aas", id: "dev.example.aas-usage", name: "aas usage", icon: "gauge",
                  accent: "orange", node: ShotData.aasNode),
            Extra(file: "tile-k8s", id: "dev.example.k8s-pods", name: "k8s pods", icon: "shippingbox",
                  accent: nil, node: ShotData.k8sNode),
        ]
        var widgets = demo.widgets
        var renders = demo.widgets.map { demo.render($0.id, at: 0) }
        for extra in extras {
            let accent = extra.accent.map { #","appearance":{"accent":"\#($0)"}"# } ?? ""
            let json = #"{"schemaVersion":1,"id":"\#(extra.id)","name":"\#(extra.name)","version":"1.0.0","icon":"\#(extra.icon)","entry":{"kind":"exec","main":"widget.sh"},"bucket":{"group":"Work","size":"M"}\#(accent)}"#
            guard let manifest = try? Manifest.decode(from: Data(json.utf8)) else {
                FileHandle.standardError.write(Data("landing-media: manifest for \(extra.file) failed\n".utf8))
                return false
            }
            widgets.append(LoadedWidget(manifest: manifest, directory: URL(fileURLWithPath: "/dev/null"),
                                        instanceID: extra.id, loadRevision: "landing"))
            renders.append(WidgetSnapshot(widgetID: extra.id, viewTree: extra.node, updatedAt: demo.now))
        }
        demo.runtime.stagePreview(widgets: widgets, renders: renders)

        demo.runtime.prefs.setGroupsOrder(["Work", "Today", "System"])
        var ok = true
        for dark in [false, true] {
            ok = popover(dark: dark, to: dir.appendingPathComponent(dark ? "popover-dark.png" : "popover-light.png")) && ok
        }
        let tiles: [(file: String, id: String)] = [
            ("tile-today", LandingDemo.ID.today), ("tile-weather", LandingDemo.ID.weather),
            ("tile-battery", LandingDemo.ID.battery), ("tile-system", LandingDemo.ID.system),
        ] + extras.map { ($0.file, $0.id) }
        for tile in tiles {
            guard let widget = widgets.first(where: { $0.id == tile.id }) else { return false }
            ok = self.tile(widget, to: dir.appendingPathComponent("\(tile.file).png")) && ok
        }
        ok = builder(to: dir.appendingPathComponent("builder.png")) && ok
        // Back to the demo shelf, should anything record after this.
        demo.runtime.stagePreview(widgets: demo.widgets, renders: demo.widgets.map { demo.render($0.id, at: 0) })
        return ok
    }

    /// The popup on its first page, on glass over the desktop.
    private func popover(dark: Bool, to url: URL) -> Bool {
        demo.pager.index = 0
        let host = HostedView(AnyView(RootView(runtime: demo.runtime, pager: demo.pager)), dark: dark)
        guard let shelf = host.layer(scale: 2, settle: 0.6) else { return false }
        let margin: CGFloat = 28
        let size = CGSize(width: shelf.size.width + 2 * margin, height: shelf.size.height + 2 * margin)
        guard let wallpaper = LandingWallpaper.make(size: size, dark: dark) else { return false }
        let frame = CGRect(origin: CGPoint(x: margin, y: margin), size: shelf.size)
        let view = ZStack(alignment: .topLeading) {
            wallpaper.view
            ZStack(alignment: .topLeading) {
                LandingGlass(wallpaper: wallpaper, frame: frame)
                shelf.view.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .offset(x: margin, y: margin)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        guard let image = landingFrame(view, size: size, scale: 2) else { return false }
        return LandingMediaMode.writePNG(image, to: url)
    }

    /// One card as the shelf draws it, on a slice of light popup.
    private func tile(_ widget: LoadedWidget, to url: URL) -> Bool {
        // As wide as the popup, so the card lays out as it does there.
        let host = HostedView(AnyView(
            WidgetCardView(widget: widget, runtime: demo.runtime)
                .padding(Spacing.cardGap)
                .frame(width: RootView.defaultSize.width)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Fill.hairline, lineWidth: 1)
                )
                .padding(4)
        ), dark: false)
        guard let image = host.capture(scale: 2, settle: 0.3) else { return false }
        return LandingMediaMode.writePNG(image, to: url)
    }

    /// The BarShelf window on Create, where the widget builder lives.
    private func builder(to url: URL) -> Bool {
        let size = CGSize(width: 980, height: 620)
        let host = HostedView(AnyView(
            HubView(runtime: demo.runtime, appPrefs: demo.runtime.appPrefs, model: HubModel(tab: .create))
        ), dark: true)
        guard let content = host.layer(size: size, scale: 2, settle: 0.8) else { return false }
        let margin: CGFloat = 36
        let titleBar: CGFloat = 30
        let canvas = CGSize(width: size.width + 2 * margin, height: size.height + titleBar + 2 * margin)
        guard let wallpaper = LandingWallpaper.make(size: canvas, dark: true) else { return false }
        let view = ZStack(alignment: .topLeading) {
            wallpaper.view
            VStack(spacing: 0) {
                // The title bar the window's content sits under.
                LandingTrafficLights()
                    .padding(.leading, Spacing.m)
                    .frame(maxWidth: .infinity, minHeight: titleBar, alignment: .leading)
                content.view
            }
                .frame(width: size.width, height: size.height + titleBar)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Fill.hairline, lineWidth: 1))
                .elevation(.float)
                .offset(x: margin, y: margin)
        }
        .environment(\.colorScheme, .dark)
        guard let image = landingFrame(view, size: canvas, scale: 2) else { return false }
        return LandingMediaMode.writePNG(image, to: url)
    }
}

/// A window's close, minimise and zoom buttons.
struct LandingTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
        }
    }
}
#endif
