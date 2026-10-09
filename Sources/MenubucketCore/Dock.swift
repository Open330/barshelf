import Foundation

/// The BarShelf Dock (R15): a bar on a screen edge carrying apps, folders,
/// files, links, Shortcuts, and BarShelf widgets, arranged in profiles the
/// user switches between. Persisted at
/// `~/Library/Application Support/barshelf/dock.json`.
///
/// Pure Codable model (UI-free, unit-testable). Missing keys decode to their
/// defaults and unknown item types are dropped, so files written by older or
/// newer builds keep loading.
public struct DockConfiguration: Codable, Equatable, Sendable {
    /// How the BarShelf Dock relates to the Apple Dock.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No BarShelf Dock. Profiles still switch the Apple Dock layout when
        /// that is turned on.
        case off
        /// The BarShelf Dock alongside the Apple Dock.
        case alongside
        /// The BarShelf Dock instead of the Apple Dock, which is hidden.
        case replace

        public var showsDock: Bool { self != .off }
    }

    public enum Style: String, Codable, CaseIterable, Sendable {
        /// Like the Apple Dock: glass bar, icons, magnification.
        case classic
        /// A sturdier bar with labels, suited to widgets.
        case shelf
    }

    public enum Edge: String, Codable, CaseIterable, Sendable {
        case bottom, left, right

        public var isVertical: Bool { self != .bottom }
    }

    public var mode: Mode
    public var style: Style
    public var edge: Edge
    /// App icon size in points.
    public var tileSize: Double
    /// How thick a widget tile is (its height on the bottom edge, its width on
    /// a side edge), in points.
    public var widgetSize: Double
    public var magnification: Bool
    /// Slide away until the pointer reaches the screen edge.
    public var autoHide: Bool
    /// Apps that are running but not in the profile, after a separator.
    public var showRunningApps: Bool
    public var showTrash: Bool
    /// How much a hovered icon grows: 0 is barely, 1 is double size.
    public var magnificationAmount: Double = DockConfiguration.defaultMagnificationAmount
    /// The dots under running apps.
    public var showIndicators: Bool = true
    /// An app bounces while it launches from the dock.
    public var animateOpening: Bool = true
    /// Seconds the pointer rests at the edge before an auto-hidden dock
    /// comes out.
    public var autoHideDelay: Double = DockConfiguration.defaultAutoHideDelay
    /// Which display the dock is on.
    public var display: Display = .main
    /// How a folder opens: a grid of its contents, or a menu.
    public var folderView: FolderView = .grid
    /// Recently used apps that are neither in the profile nor open, after
    /// the open ones — the Apple Dock's "suggested and recent apps".
    public var showRecentApps: Bool = false
    /// Icon size follows the Apple Dock's, even as it changes.
    public var matchAppleDockSize: Bool = true
    /// In a full-screen app the dock waits at the edge, as the Apple Dock
    /// does, instead of staying out of the full-screen Space altogether.
    public var showInFullScreen: Bool = true
    /// How many recent apps that section shows.
    public static let recentAppLimit = 3

    public enum FolderView: String, Codable, CaseIterable, Sendable {
        /// A grid of icons above the dock, like the Apple Dock's stacks.
        case grid
        /// A menu, with subfolders as submenus.
        case list
    }

    public enum Display: String, Codable, CaseIterable, Sendable {
        /// The display with the menu bar.
        case main
        /// Follows the pointer to the display it rests at the edge of, as the
        /// Apple Dock does.
        case pointer
    }

    public var profiles: [DockProfile]
    public var activeProfileID: String
    /// ⌃⌥1…9 switch to the first nine profiles.
    public var profileHotkeysEnabled: Bool
    /// Switching profiles also rewrites the Apple Dock's pinned items from
    /// the profile's saved layout.
    public var appleDockLayouts: Bool
    /// The Apple Dock's own hide settings from before `replace` hid it. Kept
    /// until they are put back, so a crash cannot strand the user without a
    /// Dock.
    public var appleDockBackup: AppleDockVisibility?

    /// The Apple Dock's own range.
    public static let tileSizeRange: ClosedRange<Double> = 16...128
    public static let widgetSizeRange: ClosedRange<Double> = 72...220
    public static let defaultTileSize: Double = 52
    public static let defaultWidgetSize: Double = 110
    public static let magnificationAmountRange: ClosedRange<Double> = 0.1...1
    public static let defaultMagnificationAmount: Double = 0.5
    public static let autoHideDelayRange: ClosedRange<Double> = 0...2
    public static let defaultAutoHideDelay: Double = 0.2
    /// Profiles past this many cannot get a ⌃⌥ number.
    public static let hotkeyProfileLimit = 9

    public init(
        mode: Mode = .off,
        style: Style = .classic,
        edge: Edge = .bottom,
        tileSize: Double = DockConfiguration.defaultTileSize,
        widgetSize: Double = DockConfiguration.defaultWidgetSize,
        magnification: Bool = true,
        autoHide: Bool = false,
        showRunningApps: Bool = true,
        showTrash: Bool = true,
        profiles: [DockProfile] = [],
        activeProfileID: String = "",
        profileHotkeysEnabled: Bool = false,
        appleDockLayouts: Bool = false,
        appleDockBackup: AppleDockVisibility? = nil
    ) {
        self.mode = mode
        self.style = style
        self.edge = edge
        self.tileSize = tileSize
        self.widgetSize = widgetSize
        self.magnification = magnification
        self.autoHide = autoHide
        self.showRunningApps = showRunningApps
        self.showTrash = showTrash
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.profileHotkeysEnabled = profileHotkeysEnabled
        self.appleDockLayouts = appleDockLayouts
        self.appleDockBackup = appleDockBackup
        normalize()
    }

    /// Brings every field into its allowed range: sizes are clamped, there is
    /// always at least one profile, ids are unique, and the active profile
    /// exists.
    public mutating func normalize() {
        tileSize = Self.clamp(tileSize, to: Self.tileSizeRange, fallback: Self.defaultTileSize)
        widgetSize = Self.clamp(widgetSize, to: Self.widgetSizeRange, fallback: Self.defaultWidgetSize)
        magnificationAmount = Self.clamp(
            magnificationAmount, to: Self.magnificationAmountRange, fallback: Self.defaultMagnificationAmount
        )
        autoHideDelay = Self.clamp(autoHideDelay, to: Self.autoHideDelayRange, fallback: Self.defaultAutoHideDelay)
        if profiles.isEmpty {
            profiles = [DockProfile(id: DockProfile.defaultID, name: DockProfile.defaultName)]
        }
        var seenProfiles: Set<String> = []
        for index in profiles.indices {
            profiles[index].normalize()
            while !seenProfiles.insert(profiles[index].id).inserted {
                profiles[index].id = UUID().uuidString
            }
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public var activeProfile: DockProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles[0]
    }

    public var activeProfileIndex: Int {
        profiles.firstIndex { $0.id == activeProfileID } ?? 0
    }

    /// Finds a profile the way a person names it on the command line or in a
    /// Shortcut: its id, its name (any case), or its 1-based position.
    public func profile(matching query: String) -> DockProfile? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let byID = profiles.first(where: { $0.id == trimmed }) { return byID }
        if let byName = profiles.first(where: {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) { return byName }
        if let position = Int(trimmed), profiles.indices.contains(position - 1) {
            return profiles[position - 1]
        }
        return nil
    }

    /// The profile `offset` steps from the active one, wrapping around.
    public func profile(offsetFromActive offset: Int) -> DockProfile {
        let count = profiles.count
        let index = ((activeProfileIndex + offset) % count + count) % count
        return profiles[index]
    }

    /// The widgets the active profile places in the dock, in order.
    public var activeWidgetIDs: [String] {
        activeProfile.items.compactMap { item in
            if case .widget(let id) = item.kind { return id }
            return nil
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case mode, style, edge, tileSize, widgetSize, magnification, autoHide
        case showRunningApps, showTrash, profiles, activeProfileID
        case profileHotkeysEnabled, appleDockLayouts, appleDockBackup
        case magnificationAmount, showIndicators, animateOpening, autoHideDelay, display
        case folderView, showRecentApps, showInFullScreen, matchAppleDockSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DockConfiguration()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? defaults.mode
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? defaults.style
        edge = (try? c.decodeIfPresent(Edge.self, forKey: .edge)) ?? defaults.edge
        tileSize = (try? c.decodeIfPresent(Double.self, forKey: .tileSize)) ?? defaults.tileSize
        widgetSize = (try? c.decodeIfPresent(Double.self, forKey: .widgetSize)) ?? defaults.widgetSize
        magnification = (try? c.decodeIfPresent(Bool.self, forKey: .magnification)) ?? defaults.magnification
        autoHide = (try? c.decodeIfPresent(Bool.self, forKey: .autoHide)) ?? defaults.autoHide
        showRunningApps = (try? c.decodeIfPresent(Bool.self, forKey: .showRunningApps)) ?? defaults.showRunningApps
        showTrash = (try? c.decodeIfPresent(Bool.self, forKey: .showTrash)) ?? defaults.showTrash
        profiles = (try? c.decodeIfPresent(LenientArray<DockProfile>.self, forKey: .profiles))?.elements ?? []
        activeProfileID = (try? c.decodeIfPresent(String.self, forKey: .activeProfileID)) ?? ""
        profileHotkeysEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .profileHotkeysEnabled)) ?? false
        appleDockLayouts = (try? c.decodeIfPresent(Bool.self, forKey: .appleDockLayouts)) ?? false
        appleDockBackup = (try? c.decodeIfPresent(AppleDockVisibility.self, forKey: .appleDockBackup)) ?? nil
        magnificationAmount = (try? c.decodeIfPresent(Double.self, forKey: .magnificationAmount))
            ?? defaults.magnificationAmount
        showIndicators = (try? c.decodeIfPresent(Bool.self, forKey: .showIndicators)) ?? defaults.showIndicators
        animateOpening = (try? c.decodeIfPresent(Bool.self, forKey: .animateOpening)) ?? defaults.animateOpening
        autoHideDelay = (try? c.decodeIfPresent(Double.self, forKey: .autoHideDelay)) ?? defaults.autoHideDelay
        display = (try? c.decodeIfPresent(Display.self, forKey: .display)) ?? defaults.display
        folderView = (try? c.decodeIfPresent(FolderView.self, forKey: .folderView)) ?? defaults.folderView
        showRecentApps = (try? c.decodeIfPresent(Bool.self, forKey: .showRecentApps)) ?? defaults.showRecentApps
        showInFullScreen = (try? c.decodeIfPresent(Bool.self, forKey: .showInFullScreen)) ?? defaults.showInFullScreen
        matchAppleDockSize = (try? c.decodeIfPresent(Bool.self, forKey: .matchAppleDockSize))
            ?? defaults.matchAppleDockSize
        normalize()
    }

    // MARK: File persistence

    public static func load(from fileURL: URL) -> DockConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DockConfiguration.self, from: data)
        else { return DockConfiguration() }
        return decoded
    }

    /// Atomic write (creates the parent directory).
    public func save(to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

/// One named arrangement: what the BarShelf Dock shows, and optionally the
/// Apple Dock layout and popup page that go with it.
public struct DockProfile: Codable, Equatable, Identifiable, Sendable {
    public static let defaultID = "default"
    public static let defaultName = "Default"
    public static let defaultSymbol = "square.grid.2x2"

    public var id: String
    public var name: String
    /// SF Symbol shown in menus and the switcher.
    public var symbol: String
    public var items: [DockItem]
    /// The Apple Dock's pinned items as saved into this profile.
    public var appleDock: AppleDockLayout?
    /// The popup page to show when this profile becomes active.
    public var popupPage: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String = DockProfile.defaultSymbol,
        items: [DockItem] = [],
        appleDock: AppleDockLayout? = nil,
        popupPage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.items = items
        self.appleDock = appleDock
        self.popupPage = popupPage
        normalize()
    }

    public mutating func normalize() {
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { id = UUID().uuidString }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = Self.defaultName }
        symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if symbol.isEmpty { symbol = Self.defaultSymbol }
        let page = popupPage?.trimmingCharacters(in: .whitespacesAndNewlines)
        popupPage = (page?.isEmpty == false) ? page : nil
        var seen: Set<String> = []
        for index in items.indices {
            while !seen.insert(items[index].id).inserted {
                items[index].id = UUID().uuidString
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, items, appleDock, popupPage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? Self.defaultName
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? Self.defaultSymbol
        items = (try? c.decodeIfPresent(LenientArray<DockItem>.self, forKey: .items))?.elements ?? []
        appleDock = (try? c.decodeIfPresent(AppleDockLayout.self, forKey: .appleDock)) ?? nil
        popupPage = try? c.decodeIfPresent(String.self, forKey: .popupPage)
        normalize()
    }
}

/// Something in the BarShelf Dock.
public struct DockItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case app(path: String)
        /// A folder; `color` and `label` draw it as a coloured tile with a
        /// letter instead of the folder icon.
        case folder(path: String, color: FolderColor?, label: String?)
        case file(path: String)
        case link(url: String, title: String?)
        /// A Shortcut from the Shortcuts app, run by name.
        case shortcut(name: String)
        /// A BarShelf widget, by instance id.
        case widget(id: String)
        case spacer
        case separator
    }

    public enum FolderColor: String, Codable, CaseIterable, Sendable {
        case blue, purple, pink, red, orange, yellow, green, gray
    }

    public var id: String
    public var kind: Kind

    public init(id: String = UUID().uuidString, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The item a dropped or chosen file URL becomes: an app bundle, a folder,
    /// or a plain file.
    public static func forFile(at url: URL, isDirectory: Bool) -> DockItem {
        let path = url.standardizedFileURL.path
        if url.pathExtension.lowercased() == "app" {
            return DockItem(kind: .app(path: path))
        }
        if isDirectory {
            return DockItem(kind: .folder(path: path, color: nil, label: nil))
        }
        return DockItem(kind: .file(path: path))
    }

    /// The file this item stands for, if any.
    public var filePath: String? {
        switch kind {
        case .app(let path), .file(let path): return path
        case .folder(let path, _, _): return path
        default: return nil
        }
    }

    /// A name for menus and accessibility, without touching the disk.
    public var fallbackTitle: String {
        switch kind {
        case .app(let path):
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .folder(let path, _, let label):
            if let label, !label.isEmpty { return label }
            return (path as NSString).lastPathComponent
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .link(let url, let title):
            if let title, !title.isEmpty { return title }
            return URL(string: url)?.host ?? url
        case .shortcut(let name): return name
        case .widget(let id): return id
        case .spacer: return "Spacer"
        case .separator: return "Separator"
        }
    }

    // MARK: Codable — flat `{ "id", "type", … }`

    private enum CodingKeys: String, CodingKey {
        case id, type, path, color, label, url, title, name, widget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "app":
            kind = .app(path: try c.decode(String.self, forKey: .path))
        case "folder":
            kind = .folder(
                path: try c.decode(String.self, forKey: .path),
                color: try? c.decodeIfPresent(FolderColor.self, forKey: .color),
                label: try? c.decodeIfPresent(String.self, forKey: .label)
            )
        case "file":
            kind = .file(path: try c.decode(String.self, forKey: .path))
        case "link":
            kind = .link(
                url: try c.decode(String.self, forKey: .url),
                title: try? c.decodeIfPresent(String.self, forKey: .title)
            )
        case "shortcut":
            kind = .shortcut(name: try c.decode(String.self, forKey: .name))
        case "widget":
            kind = .widget(id: try c.decode(String.self, forKey: .widget))
        case "spacer":
            kind = .spacer
        case "separator":
            kind = .separator
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown dock item type \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch kind {
        case .app(let path):
            try c.encode("app", forKey: .type)
            try c.encode(path, forKey: .path)
        case .folder(let path, let color, let label):
            try c.encode("folder", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(color, forKey: .color)
            try c.encodeIfPresent(label, forKey: .label)
        case .file(let path):
            try c.encode("file", forKey: .type)
            try c.encode(path, forKey: .path)
        case .link(let url, let title):
            try c.encode("link", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(title, forKey: .title)
        case .shortcut(let name):
            try c.encode("shortcut", forKey: .type)
            try c.encode(name, forKey: .name)
        case .widget(let id):
            try c.encode("widget", forKey: .type)
            try c.encode(id, forKey: .widget)
        case .spacer:
            try c.encode("spacer", forKey: .type)
        case .separator:
            try c.encode("separator", forKey: .type)
        }
    }
}

/// Decodes an array element by element, dropping the ones that fail, so one
/// item from a newer build does not cost the user the whole list.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Any JSON value: advances past the element whatever it is.
                _ = try? container.decode(JSONValue.self)
            }
        }
        self.elements = elements
    }
}
