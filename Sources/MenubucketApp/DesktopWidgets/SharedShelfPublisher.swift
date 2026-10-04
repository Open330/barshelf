import AppKit
import CryptoKit
import Foundation
import MenubucketCore
import QuickLookThumbnailing
import Security
import WidgetKit

/// Keeps the macOS widget extension's view of BarShelf current (R14): the
/// list of widgets it may show and each one's last render, written into the
/// shared App Group container, and a nudge to WidgetKit when they change.
///
/// Inert in builds that do not carry the App Group entitlement (ad-hoc dev
/// builds): touching a group container without it would make macOS ask the
/// user for access to "data from other apps".
///
/// Used from the main thread only, like the runtime that owns it.
final class SharedShelfPublisher {
    /// macOS budgets widget reloads (roughly 40–70 a day). Changes inside the
    /// window are folded into one reload at its end.
    static let minimumReloadInterval: TimeInterval = 15 * 60

    private let container: URL?
    private var lastReload: Date?
    private var pendingReload: DispatchWorkItem?
    private var lastIndex: SharedShelf.Index?

    init(container: URL? = SharedShelfPublisher.entitledContainer()) {
        self.container = container
    }

    var isEnabled: Bool { container != nil }

    /// The list a user picks from when configuring a widget. Returns whether
    /// it changed.
    @discardableResult
    func publishIndex(_ entries: [SharedShelf.Entry]) -> Bool {
        guard let container else { return false }
        let index = SharedShelf.Index(entries: entries)
        guard index != lastIndex else { return false }
        lastIndex = index
        do {
            try SharedShelf.writeIndex(index, to: container)
            SharedShelf.pruneSnapshots(keeping: Set(entries.map(\.id)), in: container)
        } catch {
            NSLog("barshelf: could not write the widget index: \(error)")
        }
        return true
    }

    func publish(_ snapshot: SharedShelf.Snapshot) {
        guard let container else { return }
        let paths = Self.imagePaths(in: snapshot)
        guard !paths.isEmpty, let folder = SharedShelf.imagesDirectory(for: snapshot.widgetID, in: container) else {
            write(Self.sharing(snapshot, thumbnails: [:]), to: container)
            return
        }
        // Thumbnails first, then the snapshot that names them.
        Task { [weak self] in
            let thumbnails = await Self.exportThumbnails(paths, into: folder)
            await MainActor.run {
                self?.write(Self.sharing(snapshot, thumbnails: thumbnails), to: container)
            }
        }
    }

    private func write(_ snapshot: SharedShelf.Snapshot, to container: URL) {
        do {
            try SharedShelf.writeSnapshot(snapshot, to: container)
            scheduleReload()
        } catch {
            NSLog("barshelf: could not share \(snapshot.widgetID) with widgets: \(error)")
        }
    }

    // MARK: - Thumbnails

    /// Most thumbnails exported per widget: a large widget shows twelve.
    static let maximumThumbnails = 12
    static let thumbnailSize = CGSize(width: 128, height: 128)

    /// Files the snapshot's items show, in order, at most `maximumThumbnails`.
    static func imagePaths(in snapshot: SharedShelf.Snapshot) -> [String] {
        var seen: Set<String> = []
        return snapshot.parts.compactMap(\.summary?.imagePath)
            .filter { seen.insert($0).inserted }
            .prefix(maximumThumbnails).map { $0 }
    }

    /// The snapshot as it goes into the shared folder: thumbnails named by
    /// their exported file, and no local file paths at all.
    static func sharing(_ snapshot: SharedShelf.Snapshot, thumbnails: [String: String]) -> SharedShelf.Snapshot {
        var shared = snapshot
        for index in shared.parts.indices {
            guard var summary = shared.parts[index].summary else { continue }
            summary.thumbnail = summary.imagePath.flatMap { thumbnails[$0] }
            summary.imagePath = nil
            shared.parts[index].summary = summary
        }
        shared.summary?.imagePath = nil
        return shared
    }

    /// Writes a small PNG per file into `folder`, named by the file's path
    /// and modification time so an unchanged file is not redone, and removes
    /// the PNGs no longer needed. Returns path → file name.
    static func exportThumbnails(_ paths: [String], into folder: URL) async -> [String: String] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let digest = SHA256.hash(data: Data("\(path)|\(modified?.timeIntervalSince1970 ?? 0)".utf8))
            let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
            let target = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                names[path] = name
                continue
            }
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: thumbnailSize, scale: 2, representationTypes: .all
            )
            guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                  let tiff = thumbnail.nsImage.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  (try? png.write(to: target, options: .atomic)) != nil
            else { continue }
            names[path] = name
        }
        let keep = Set(names.values)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        return names
    }

    /// Takes a widget out of the shared folder at once — for one that turned
    /// out to be sensitive.
    func withdraw(widgetID: String) {
        guard let container else { return }
        SharedShelf.removeSnapshot(widgetID: widgetID, from: container)
        scheduleReload()
    }

    private func scheduleReload(now: Date = Date()) {
        guard pendingReload == nil else { return }
        let wait = Self.reloadDelay(lastReload: lastReload, now: now)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: SharedShelf.widgetKind)
        }
        pendingReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// How long to wait before the next reload: none if the last was long
    /// enough ago, otherwise until the window closes.
    static func reloadDelay(lastReload: Date?, now: Date) -> TimeInterval {
        guard let lastReload else { return 0 }
        return max(0, minimumReloadInterval - now.timeIntervalSince(lastReload))
    }

    /// The group container, when this copy of BarShelf is signed with the
    /// App Group entitlement; nil otherwise.
    static func entitledContainer() -> URL? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ),
              let groups = value as? [String],
              groups.contains(SharedShelf.appGroupID)
        else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedShelf.appGroupID
        )
    }
}
