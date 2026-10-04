import AppKit
import CryptoKit
import Foundation
import MenubucketCore
import QuickLookThumbnailing
import Security
import UniformTypeIdentifiers
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
        Task { @MainActor [weak self] in
            let thumbnails = await Self.exportThumbnails(paths, into: folder)
            self?.write(Self.sharing(snapshot, thumbnails: thumbnails), to: container)
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
    ///
    /// A file with no picture yet gets its icon, named `-icon.png`, and is
    /// tried again after `iconRetryInterval` — so a picture that becomes
    /// available later replaces the icon instead of the icon sticking.
    static func exportThumbnails(_ paths: [String], into folder: URL, now: Date = Date()) async -> [String: String] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // `v2`: earlier builds saved stand-in icons under the picture's
            // name; a new name lets the prune below clear them.
            let digest = SHA256.hash(data: Data("v2|\(path)|\(modified?.timeIntervalSince1970 ?? 0)".utf8))
            let base = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
            let picture = base + ".png"
            let icon = base + "-icon.png"
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(picture).path) {
                names[path] = picture
                continue
            }
            let iconURL = folder.appendingPathComponent(icon)
            let iconMade = (try? iconURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let iconMade, now.timeIntervalSince(iconMade) < iconRetryInterval {
                names[path] = icon
                continue
            }
            if let png = await pictureThumbnail(of: url), write(png, to: folder.appendingPathComponent(picture)) {
                names[path] = picture
                continue
            }
            if let png = await MainActor.run(body: { iconThumbnail(of: url) }), write(png, to: iconURL) {
                names[path] = icon
            }
        }
        let keep = Set(names.values)
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        return names
    }

    /// How long an icon stands in before the picture is tried again.
    static let iconRetryInterval: TimeInterval = 10 * 60
    /// Largest cloud-only image read to make a picture of it.
    static let maximumDownloadBytes = 25 * 1024 * 1024

    /// The file's picture: Quick Look's thumbnail, or — for an image kept
    /// only in the cloud (OneDrive, iCloud), which Quick Look cannot preview
    /// — one read from the image itself, which makes the provider download it.
    private static func pictureThumbnail(of url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: thumbnailSize, scale: 2, representationTypes: .thumbnail
        )
        if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
           let png = pngData(thumbnail.nsImage) {
            return png
        }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard values?.contentType?.conforms(to: .image) == true,
              (values?.fileSize ?? .max) <= maximumDownloadBytes
        else { return nil }
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: Int(thumbnailSize.width * 2),
                  ] as CFDictionary)
            else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }.value
    }

    @MainActor
    private static func iconThumbnail(of url: URL) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = thumbnailSize
        return pngData(icon)
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: .atomic)) != nil
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
