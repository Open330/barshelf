import Foundation

/// The Apple Dock's pinned items as saved into a dock profile (R15).
///
/// The `persistent-apps` and `persistent-others` arrays are kept verbatim —
/// bookmark data and all — as binary property lists, so putting a layout back
/// loses nothing. The names are only for showing what a profile holds.
public struct AppleDockLayout: Codable, Equatable, Sendable {
    public var apps: Data
    public var others: Data
    public var capturedAt: Date
    public var appNames: [String]
    public var otherNames: [String]

    public init(appTiles: [Any], otherTiles: [Any], capturedAt: Date = Date()) {
        apps = Self.encode(appTiles)
        others = Self.encode(otherTiles)
        self.capturedAt = capturedAt
        appNames = AppleDockTiles.labels(of: appTiles)
        otherNames = AppleDockTiles.labels(of: otherTiles)
    }

    public var appTiles: [Any] { Self.decode(apps) }
    public var otherTiles: [Any] { Self.decode(others) }

    static func encode(_ tiles: [Any]) -> Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: tiles, format: .binary, options: 0
        )) ?? Data()
    }

    static func decode(_ data: Data) -> [Any] {
        guard !data.isEmpty,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [] }
        return value as? [Any] ?? []
    }
}

/// The Apple Dock's hide settings, as found before BarShelf hid it. `nil`
/// means the key was not set, which is how it is put back.
public struct AppleDockVisibility: Codable, Equatable, Sendable {
    public var autohide: Bool?
    public var autohideDelay: Double?

    public init(autohide: Bool?, autohideDelay: Double?) {
        self.autohide = autohide
        self.autohideDelay = autohideDelay
    }
}

/// Reading and building the Dock's tile dictionaries. Pure; no I/O.
public enum AppleDockTiles {
    /// What a tile is called: its label, else the last part of its URL.
    public static func labels(of tiles: [Any]) -> [String] {
        tiles.compactMap { tile in
            guard let tile = tile as? [String: Any] else { return nil }
            let type = tile["tile-type"] as? String ?? ""
            if type.hasSuffix("spacer-tile") { return nil }
            let data = tile["tile-data"] as? [String: Any] ?? [:]
            if let label = data["file-label"] as? String, !label.isEmpty { return label }
            if let label = data["label"] as? String, !label.isEmpty { return label }
            if let url = fileURL(of: tile) {
                return (url.lastPathComponent as NSString).deletingPathExtension
            }
            return nil
        }
    }

    /// The file a tile points at, for app, file, and folder tiles.
    public static func fileURL(of tile: Any) -> URL? {
        guard let tile = tile as? [String: Any],
              let data = tile["tile-data"] as? [String: Any],
              let fileData = data["file-data"] as? [String: Any],
              let string = fileData["_CFURLString"] as? String
        else { return nil }
        if let url = URL(string: string), url.isFileURL { return url }
        return URL(fileURLWithPath: string)
    }

    /// Whether the tile is a spacer of any width.
    public static func isSpacer(_ tile: Any) -> Bool {
        ((tile as? [String: Any])?["tile-type"] as? String)?.hasSuffix("spacer-tile") == true
    }

    /// What tells two layouts apart: each tile's type and target, in order.
    /// Bookkeeping the Dock rewrites on its own (GUIDs, dates) is left out, so
    /// putting back a layout that is already showing is a no-op.
    public static func signature(of tiles: [Any]) -> [String] {
        tiles.map { tile in
            let type = (tile as? [String: Any])?["tile-type"] as? String ?? "?"
            let url = fileURL(of: tile)?.standardizedFileURL.path
                ?? ((tile as? [String: Any])?["tile-data"] as? [String: Any])?["url"]
                    .flatMap { ($0 as? [String: Any])?["_CFURLString"] as? String }
                ?? ""
            return "\(type)|\(url)"
        }
    }

    /// A minimal tile for an app bundle — what dockutil writes; the Dock fills
    /// in the rest on its next launch.
    public static func appTile(path: String) -> [String: Any] {
        [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": URL(fileURLWithPath: path, isDirectory: true).absoluteString,
                    "_CFURLStringType": 15,
                ],
            ],
        ]
    }

    /// A minimal folder tile for the Dock's right-hand side.
    public static func folderTile(path: String) -> [String: Any] {
        [
            "tile-type": "directory-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": URL(fileURLWithPath: path, isDirectory: true).absoluteString,
                    "_CFURLStringType": 15,
                ],
                // Fan/grid by kind, sorted by date added, shown as a folder.
                "arrangement": 2,
                "displayas": 1,
                "showas": 0,
            ],
        ]
    }
}

/// Where the Apple Dock's preferences are read and written. The live store
/// is `CFPreferences` for `com.apple.dock`; tests use a dictionary.
public protocol AppleDockDefaults: AnyObject {
    func value(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func synchronize()
}

public final class SystemAppleDockDefaults: AppleDockDefaults {
    private let domain = "com.apple.dock" as CFString

    public init() {}

    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    public func set(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    }

    public func synchronize() {
        CFPreferencesAppSynchronize(domain)
    }
}

/// Reads, rewrites, hides, and restores the Apple Dock (R15). The Dock reads
/// its preferences at launch, so every change ends with a Dock restart
/// (launchd brings it straight back).
public final class AppleDock {
    public static let appsKey = "persistent-apps"
    public static let othersKey = "persistent-others"
    public static let autohideKey = "autohide"
    public static let autohideDelayKey = "autohide-delay"
    public static let orientationKey = "orientation"
    /// Long enough that the Dock never comes up in practice.
    public static let hiddenDelay: Double = 1000
    /// Layout backups kept before each rewrite.
    public static let backupLimit = 10

    private let defaults: AppleDockDefaults
    private let restart: () -> Void
    private let backupDirectory: URL?

    public init(
        defaults: AppleDockDefaults = SystemAppleDockDefaults(),
        backupDirectory: URL? = nil,
        restart: @escaping () -> Void = AppleDock.restartDock
    ) {
        self.defaults = defaults
        self.backupDirectory = backupDirectory
        self.restart = restart
    }

    // MARK: Layout

    public func currentLayout(now: Date = Date()) -> AppleDockLayout {
        defaults.synchronize()
        return AppleDockLayout(
            appTiles: defaults.value(forKey: Self.appsKey) as? [Any] ?? [],
            otherTiles: defaults.value(forKey: Self.othersKey) as? [Any] ?? [],
            capturedAt: now
        )
    }

    /// Puts `layout` into the Apple Dock. Returns false, without restarting
    /// the Dock, when it is already showing that layout.
    @discardableResult
    public func apply(_ layout: AppleDockLayout) -> Bool {
        let current = currentLayout()
        let newApps = layout.appTiles
        let newOthers = layout.otherTiles
        if AppleDockTiles.signature(of: current.appTiles) == AppleDockTiles.signature(of: newApps),
           AppleDockTiles.signature(of: current.otherTiles) == AppleDockTiles.signature(of: newOthers) {
            return false
        }
        writeBackup(current)
        defaults.set(newApps, forKey: Self.appsKey)
        defaults.set(newOthers, forKey: Self.othersKey)
        defaults.synchronize()
        restart()
        return true
    }

    /// Keeps the layout about to be replaced, newest last, at most
    /// `backupLimit` files.
    private func writeBackup(_ layout: AppleDockLayout) {
        guard let backupDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let tiles: [String: Any] = [
            Self.appsKey: layout.appTiles,
            Self.othersKey: layout.otherTiles,
        ]
        let stamp = Int(layout.capturedAt.timeIntervalSince1970 * 1000)
        // The stamp sorts the files; the suffix keeps two rewrites in the same
        // millisecond from overwriting each other.
        let suffix = UUID().uuidString.prefix(8)
        let file = backupDirectory.appendingPathComponent("apple-dock-\(stamp)-\(suffix).plist")
        if let data = try? PropertyListSerialization.data(fromPropertyList: tiles, format: .xml, options: 0) {
            try? data.write(to: file, options: .atomic)
        }
        let existing = ((try? fm.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("apple-dock-") && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in existing.dropLast(Self.backupLimit) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: Visibility

    public var visibility: AppleDockVisibility {
        defaults.synchronize()
        return AppleDockVisibility(
            autohide: Self.bool(defaults.value(forKey: Self.autohideKey)),
            autohideDelay: Self.double(defaults.value(forKey: Self.autohideDelayKey))
        )
    }

    /// Whether the Dock is hidden the way `hide()` hides it.
    public var isHidden: Bool {
        let current = visibility
        return current.autohide == true && (current.autohideDelay ?? 0) >= Self.hiddenDelay / 2
    }

    /// Hides the Apple Dock and returns its settings from before, to hand
    /// back to `restore`. Already hidden → nil, nothing changes.
    public func hide() -> AppleDockVisibility? {
        guard !isHidden else { return nil }
        let before = visibility
        defaults.set(true, forKey: Self.autohideKey)
        defaults.set(Self.hiddenDelay, forKey: Self.autohideDelayKey)
        defaults.synchronize()
        restart()
        return before
    }

    /// Puts back the hide settings `hide` found.
    public func restore(_ backup: AppleDockVisibility) {
        defaults.set(backup.autohide, forKey: Self.autohideKey)
        defaults.set(backup.autohideDelay, forKey: Self.autohideDelayKey)
        defaults.synchronize()
        restart()
    }

    /// Shows the Dock when there is no backup to go by: whatever hid it, the
    /// long delay goes. Autohide itself stays as the user had it.
    public func unhideWithoutBackup() {
        guard isHidden else { return }
        defaults.set(nil, forKey: Self.autohideDelayKey)
        defaults.synchronize()
        restart()
    }

    /// "bottom", "left", or "right".
    public var orientation: String {
        defaults.synchronize()
        return defaults.value(forKey: Self.orientationKey) as? String ?? "bottom"
    }

    public static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
