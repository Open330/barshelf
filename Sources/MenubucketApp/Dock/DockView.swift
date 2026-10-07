import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// One thing drawn in the dock: a profile item, or something the dock adds
/// on its own (running apps, the Trash).
enum DockTile: Identifiable, Equatable {
    case item(DockItem)
    case running(RunningApps.App)
    case divider(String)
    case trash

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .running(let app): return "running:\(app.path)"
        case .divider(let id): return "divider:\(id)"
        case .trash: return "trash"
        }
    }

    /// Icons grow under the pointer; widgets, spacers, and dividers do not.
    var magnifies: Bool {
        switch self {
        case .item(let item):
            switch item.kind {
            case .widget, .spacer, .separator: return false
            default: return true
            }
        case .running, .trash: return true
        case .divider: return false
        }
    }
}

/// The BarShelf Dock's content (R15).
struct DockView: View {
    @ObservedObject var store: DockStore
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var running: RunningApps
    /// The pointer came onto or left the icons; the panel measures the bar
    /// only at rest, since magnified sizes would make it chase the pointer.
    let onHoverChange: (Bool) -> Void
    let onOpenSettings: () -> Void

    @State private var hoveredID: String?
    @State private var dropTargetID: String?

    static let dragPrefix = "barshelf-dock-item:"

    private var config: DockConfiguration { store.configuration }
    private var edge: DockConfiguration.Edge { config.edge }
    private var tileSize: CGFloat { CGFloat(config.tileSize) }
    private var isClassic: Bool { config.style == .classic }
    private var spacing: CGFloat { isClassic ? max(2, tileSize * 0.08) : max(6, tileSize * 0.16) }

    // MARK: Tiles

    var tiles: [DockTile] {
        Self.tiles(for: store.configuration, running: running.apps)
    }

    /// The profile's items, then running apps not among them, then the Trash.
    static func tiles(for config: DockConfiguration, running: [RunningApps.App]) -> [DockTile] {
        let items = config.activeProfile.items
        var tiles = items.map(DockTile.item)
        if config.showRunningApps {
            let pinned = Set(items.compactMap { item -> String? in
                if case .app(let path) = item.kind { return RunningApps.key(path) }
                return nil
            })
            let extra = running.filter { !pinned.contains($0.path) && $0.bundleID != Bundle.main.bundleIdentifier }
            if !extra.isEmpty {
                if !tiles.isEmpty { tiles.append(.divider("running")) }
                tiles += extra.map(DockTile.running)
            }
        }
        if config.showTrash {
            if !tiles.isEmpty { tiles.append(.divider("trash")) }
            tiles.append(.trash)
        }
        return tiles
    }

    private func scale(at index: Int, in tiles: [DockTile]) -> CGFloat {
        guard isClassic, config.magnification, let hoveredID,
              let hovered = tiles.firstIndex(where: { $0.id == hoveredID }),
              tiles[hovered].magnifies, tiles[index].magnifies
        else { return 1 }
        let distance = CGFloat(abs(index - hovered))
        return 1 + Self.maxMagnification * max(0, 1 - distance / 2.5)
    }

    static let maxMagnification: CGFloat = 0.5

    // MARK: Body

    var body: some View {
        let tiles = self.tiles
        let layout = edge.isVertical
            ? AnyLayout(VStackLayout(alignment: edge == .left ? .leading : .trailing, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: spacing))
        layout {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                tileView(tile, scale: scale(at: index, in: tiles))
            }
            if tiles.isEmpty { emptyHint }
        }
        .padding(isClassic ? max(5, tileSize * 0.12) : max(8, tileSize * 0.18))
        .background { barBackground }
        .contentShape(Rectangle())
        .contextMenu { barMenu }
        .onDrop(of: DockDrop.acceptedTypes, isTargeted: nil) { providers in
            DockDrop.receive(providers, store: store, before: nil)
        }
        .overlay(alignment: edge == .bottom ? .top : .center) { profileBanner }
        .fixedSize()
        .onChange(of: hoveredID == nil) { _, resting in onHoverChange(!resting) }
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: hoveredID)
        .animation(.easeInOut(duration: 0.2), value: tiles.map(\.id))
        // The panel is larger than the bar (room for magnified icons and
        // labels); the bar sits on the screen edge inside it.
        .padding(edgeInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edgeAlignment)
    }

    private var edgeAlignment: Alignment {
        switch edge {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var edgeInsets: EdgeInsets {
        let gap = DockPanelController.edgeGap
        switch edge {
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: gap, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: gap, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: gap)
        }
    }

    @ViewBuilder
    private var barBackground: some View {
        let shape = RoundedRectangle(cornerRadius: isClassic ? tileSize * 0.36 : 18, style: .continuous)
        if #available(macOS 26.0, *), isClassic {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(isClassic ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 2)
        }
    }

    private var emptyHint: some View {
        Text("Drop apps, folders, or files here")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(height: tileSize)
            .padding(.horizontal, Spacing.s)
    }

    @ViewBuilder
    private var profileBanner: some View {
        if let profile = store.announcedProfile {
            Label(profile.name, systemImage: profile.symbol)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .offset(y: edge == .bottom ? -44 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .allowsHitTesting(false)
                .accessibilityLabel(Text("Dock profile: \(profile.name)"))
        }
    }

    // MARK: Tile views

    @ViewBuilder
    private func tileView(_ tile: DockTile, scale: CGFloat) -> some View {
        switch tile {
        case .item(let item):
            itemView(item, scale: scale)
        case .running(let app):
            iconTile(
                id: tile.id,
                title: FileManager.default.displayName(atPath: app.path)
                    .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards]),
                image: NSWorkspace.shared.icon(forFile: app.path),
                isRunning: true, scale: scale,
                action: { DockActions.openApp(path: app.path) },
                dropFiles: { urls in DockActions.open(urls, withAppAt: app.path) }
            )
            .contextMenu { runningAppMenu(app) }
        case .divider:
            divider
        case .trash:
            iconTile(
                id: tile.id, title: String(localized: "Trash"),
                image: NSImage(named: NSImage.trashEmptyName), isRunning: false, scale: scale,
                action: DockActions.openTrash,
                dropFiles: DockActions.moveToTrash
            )
            .contextMenu {
                Button("Open") { DockActions.openTrash() }
                Divider()
                settingsButton
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: DockItem, scale: CGFloat) -> some View {
        Group {
            switch item.kind {
            case .widget(let id):
                widgetTile(item: item, widgetID: id)
            case .spacer:
                Color.clear
                    .frame(
                        width: edge.isVertical ? tileSize : tileSize * 0.5,
                        height: edge.isVertical ? tileSize * 0.5 : tileSize
                    )
                    .contentShape(Rectangle())
            case .separator:
                divider
            case .app(let path):
                iconTile(
                    id: item.id, title: DockActions.displayName(for: item),
                    image: DockActions.icon(for: item),
                    isRunning: running.isRunning(path: path), scale: scale,
                    action: { DockActions.open(item) },
                    dropFiles: { urls in DockActions.open(urls, withAppAt: path) }
                )
            case .folder(let path, let color, let label):
                iconTile(
                    id: item.id, title: DockActions.displayName(for: item),
                    image: color == nil ? DockActions.icon(for: item) : nil,
                    isRunning: false, scale: scale,
                    action: { Self.showFolderMenu(path: path) },
                    dropFiles: nil,
                    custom: color.map { color in
                        AnyView(FolderBadge(color: color, label: label ?? DockActions.displayName(for: item)))
                    }
                )
            case .link(let url, _):
                iconTile(
                    id: item.id, title: DockActions.displayName(for: item),
                    image: nil, isRunning: false, scale: scale,
                    action: { DockActions.open(item) }, dropFiles: nil,
                    custom: AnyView(LinkBadge(url: url))
                )
            case .file, .shortcut:
                iconTile(
                    id: item.id, title: DockActions.displayName(for: item),
                    image: DockActions.icon(for: item), isRunning: false, scale: scale,
                    action: { DockActions.open(item) }, dropFiles: nil
                )
            }
        }
        .contextMenu { itemMenu(item) }
        .onDrag {
            NSItemProvider(object: "\(Self.dragPrefix)\(item.id)" as NSString)
        }
        .onDrop(of: DockDrop.acceptedTypes, isTargeted: Binding(
            get: { dropTargetID == item.id },
            set: { dropTargetID = $0 ? item.id : (dropTargetID == item.id ? nil : dropTargetID) }
        )) { providers in
            DockDrop.receive(providers, store: store, before: item.id)
        }
        .overlay(alignment: edge.isVertical ? .top : .leading) {
            if dropTargetID == item.id {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(
                        width: edge.isVertical ? nil : 3,
                        height: edge.isVertical ? 3 : nil
                    )
                    .offset(x: edge.isVertical ? 0 : -spacing / 2 - 1.5, y: edge.isVertical ? -spacing / 2 - 1.5 : 0)
                    .allowsHitTesting(false)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(
                width: edge.isVertical ? tileSize * 0.8 : 1,
                height: edge.isVertical ? 1 : tileSize * 0.8
            )
            .padding(edge.isVertical ? .vertical : .horizontal, 2)
            .frame(maxHeight: edge.isVertical ? nil : tileSize, alignment: .center)
    }

    /// An app, folder, file, link, Shortcut, or the Trash.
    private func iconTile(
        id: String,
        title: String,
        image: NSImage?,
        isRunning: Bool,
        scale: CGFloat,
        action: @escaping () -> Void,
        dropFiles: (([URL]) -> Void)?,
        custom: AnyView? = nil
    ) -> some View {
        let grown = tileSize * scale
        let anchor: UnitPoint = switch edge {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
        return Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let custom {
                        custom
                    } else if let image {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: tileSize, height: tileSize)
                .scaleEffect(scale, anchor: anchor)
                .frame(
                    width: edge.isVertical ? tileSize : grown,
                    height: edge.isVertical ? grown : tileSize,
                    alignment: Alignment(horizontal: edge == .left ? .leading : edge == .right ? .trailing : .center,
                                         vertical: edge == .bottom ? .bottom : .center)
                )
                if !isClassic {
                    Text(title)
                        .font(.system(size: max(9, tileSize * 0.2)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: tileSize * 1.3)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: runningDotAlignment) {
                if isRunning {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 4, height: 4)
                        .offset(runningDotOffset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(DockPressStyle())
        .overlay(alignment: labelAlignment) {
            if isClassic, hoveredID == id {
                HoverLabel(title: title)
                    .fixedSize()
                    .offset(labelOffset(grown: grown))
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
        }
        .modifier(FileDropModifier(store: store, addsFolders: id != DockTile.trash.id, dropFiles: dropFiles))
        .accessibilityLabel(Text(title))
        .accessibilityValue(isRunning ? Text("Running") : Text(""))
    }

    private var runningDotAlignment: Alignment {
        switch edge {
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var runningDotOffset: CGSize {
        let gap = isClassic ? max(4, tileSize * 0.1) : 2
        switch edge {
        case .bottom: return CGSize(width: 0, height: isClassic ? gap : gap + 2)
        case .left: return CGSize(width: -gap, height: 0)
        case .right: return CGSize(width: gap, height: 0)
        }
    }

    private var labelAlignment: Alignment {
        switch edge {
        case .bottom: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }

    private func labelOffset(grown: CGFloat) -> CGSize {
        let lift = grown - tileSize + 30
        switch edge {
        case .bottom: return CGSize(width: 0, height: -lift)
        case .left: return CGSize(width: lift + 40, height: 0)
        case .right: return CGSize(width: -lift - 40, height: 0)
        }
    }

    // MARK: Widgets

    private func widgetFrame(for widgetID: String) -> CGSize {
        let thickness = CGFloat(config.widgetSize)
        let size = runtime.effectiveSize(for: widgetID)
        if edge.isVertical {
            let factor: CGFloat = switch size {
            case "XS": 0.6
            case "S": 0.8
            case "L": 1.5
            default: 1.0
            }
            return CGSize(width: thickness * 2, height: thickness * factor)
        }
        let factor: CGFloat = switch size {
        case "XS", "S": 1.6
        case "L": 3.0
        default: 2.4
        }
        return CGSize(width: thickness * factor, height: thickness)
    }

    @ViewBuilder
    private func widgetTile(item: DockItem, widgetID: String) -> some View {
        let frame = widgetFrame(for: widgetID)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let widget = runtime.widgets.first(where: { $0.id == widgetID }) {
            WidgetCardView(widget: widget, runtime: runtime, compactHeight: frame.height, placement: .single)
                .frame(width: frame.width, height: frame.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else {
            VStack(spacing: Spacing.xxs) {
                Image(systemName: "questionmark.square.dashed").font(.title2)
                Text("Widget not installed").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(width: frame.width, height: frame.height)
            .background(Color.primary.opacity(0.05), in: shape)
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func itemMenu(_ item: DockItem) -> some View {
        switch item.kind {
        case .app(let path):
            Button("Open") { DockActions.open(item) }
            if let app = running.runningApplication(path: path) {
                Button("Hide") { app.hide() }
                Button("Quit") { app.terminate() }
            }
            Button("Show in Finder") { DockActions.revealInFinder(path: path) }
        case .folder(let path, let color, let label):
            Button("Open") { DockActions.open(item) }
            Button("Show in Finder") { DockActions.revealInFinder(path: path) }
            Menu("Color") {
                Button("None") {
                    store.replaceItem(DockItem(id: item.id, kind: .folder(path: path, color: nil, label: label)))
                }
                ForEach(DockItem.FolderColor.allCases, id: \.self) { option in
                    Button(FolderBadge.name(option)) {
                        store.replaceItem(DockItem(id: item.id, kind: .folder(path: path, color: option, label: label)))
                    }
                    .disabled(option == color)
                }
            }
        case .file(let path):
            Button("Open") { DockActions.open(item) }
            Button("Show in Finder") { DockActions.revealInFinder(path: path) }
        case .link(let url, _):
            Button("Open") { DockActions.open(item) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        case .shortcut:
            Button("Run Shortcut") { DockActions.open(item) }
            Button("Open Shortcuts") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                    DockActions.openApp(path: url.path)
                }
            }
        case .widget(let id):
            Button("Show in BarShelf") { DockActions.open(item) }
            Button("Refresh") { runtime.refresh(widgetID: id) }
        case .spacer, .separator:
            EmptyView()
        }
        Divider()
        Button("Remove from Dock", role: .destructive) { store.removeItem(item.id) }
        Divider()
        profilesMenu
        settingsButton
    }

    @ViewBuilder
    private func runningAppMenu(_ app: RunningApps.App) -> some View {
        Button("Keep in Dock") {
            store.addItems([DockItem(kind: .app(path: app.path))])
        }
        if let running = NSRunningApplication(processIdentifier: app.processID) {
            Button("Hide") { running.hide() }
            Button("Quit") { running.terminate() }
        }
        Button("Show in Finder") { DockActions.revealInFinder(path: app.path) }
        Divider()
        settingsButton
    }

    @ViewBuilder
    private var barMenu: some View {
        profilesMenu
        settingsButton
    }

    @ViewBuilder
    private var profilesMenu: some View {
        if config.profiles.count > 1 {
            Menu("Profile") {
                ForEach(config.profiles) { profile in
                    Toggle(isOn: Binding(
                        get: { profile.id == config.activeProfileID },
                        set: { _ in store.activate(profileID: profile.id) }
                    )) {
                        Label(profile.name, systemImage: profile.symbol)
                    }
                }
            }
        }
    }

    private var settingsButton: some View {
        Button("Dock Settings…") { onOpenSettings() }
    }

    static func showFolderMenu(path: String) {
        DockActions.folderMenu(path: path).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Pieces

private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.25 : 0)
    }
}

private struct HoverLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// A folder drawn as a coloured tile with a letter or two.
struct FolderBadge: View {
    let color: DockItem.FolderColor
    let label: String

    static func color(_ color: DockItem.FolderColor) -> Color {
        switch color {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .gray: return .gray
        }
    }

    static func name(_ color: DockItem.FolderColor) -> String {
        switch color {
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .red: return String(localized: "Red")
        case .orange: return String(localized: "Orange")
        case .yellow: return String(localized: "Yellow")
        case .green: return String(localized: "Green")
        case .gray: return String(localized: "Gray")
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let base = Self.color(color)
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [base.opacity(0.85), base], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .center) {
                    Text(String(label.prefix(2)).uppercased())
                        .font(.system(size: side * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .padding(side * 0.08)
                }
                .overlay(alignment: .topLeading) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: side * 0.2))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(side * 0.1)
                }
                .padding(side * 0.06)
        }
    }
}

/// A web link drawn as a globe tile with the site's first letter.
private struct LinkBadge: View {
    let url: String

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Text(String(host.prefix(1)).uppercased())
                        .font(.system(size: side * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "globe")
                        .font(.system(size: side * 0.2, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(side * 0.1)
                }
                .padding(side * 0.06)
        }
    }
}

// MARK: - Drag and drop

/// Files dropped on an app open in it, or on the Trash go to it. Only tiles
/// that take files get the handler, so the rest pass drops to the dock.
private struct FileDropModifier: ViewModifier {
    let store: DockStore
    /// Apps and folders dropped on an app are being added, not opened; on
    /// the Trash they are thrown away like anything else.
    let addsFolders: Bool
    let dropFiles: (([URL]) -> Void)?

    func body(content: Content) -> some View {
        if let dropFiles {
            content.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                DockDrop.loadFileURLs(providers) { urls in
                    if addsFolders, urls.allSatisfy(\.hasDirectoryPath) {
                        store.addItems(urls.map { DockItem.forFile(at: $0, isDirectory: true) })
                    } else {
                        dropFiles(urls)
                    }
                }
            }
        } else {
            content
        }
    }
}

enum DockDrop {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .text]

    /// Files become items, web links become link items, and a dragged dock
    /// item moves. `before` is the item the drop landed on, if any.
    static func receive(_ providers: [NSItemProvider], store: DockStore, before: String?) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            return loadFileURLs(providers) { urls in
                let items = urls.map { url -> DockItem in
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    return DockItem.forFile(at: url, isDirectory: isDirectory.boolValue)
                }
                store.addItems(items, before: before)
            }
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
                DispatchQueue.main.async {
                    store.addItems([DockItem(kind: .link(url: url.absoluteString, title: url.host))], before: before)
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let text = value as? String, text.hasPrefix(DockView.dragPrefix) else { return }
                let id = String(text.dropFirst(DockView.dragPrefix.count))
                DispatchQueue.main.async { store.moveItem(id, before: before) }
            }
            return true
        }
        return false
    }

    /// Loads every file URL among the providers, then calls back on main.
    @discardableResult
    static func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                defer { group.leave() }
                let url: URL? = if let data = value as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    value as? URL
                }
                guard let url else { return }
                lock.lock()
                urls.append((index, url))
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            completion(urls.sorted { $0.0 < $1.0 }.map(\.1))
        }
        return true
    }
}
