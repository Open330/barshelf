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
    private let reloadTimelines: () -> Void
    private let scheduleRefreshTimeout: (@escaping () -> Void) -> Void
    private var lastReload: Date?
    private var pendingReload: DispatchWorkItem?
    private var lastIndex: SharedShelf.Index?
    /// Thumbnail exports still running, one per widget; a newer publish or a
    /// withdrawal cancels the one before it.
    private var exports: [String: Task<Void, Never>] = [:]
    /// Bumped on every publish and withdrawal, so an export that finishes
    /// late cannot write over something newer — or bring back a widget that
    /// was taken out while it ran.
    private var generations: [String: Int] = [:]

    /// Widgets whose refresh a desktop widget asked for: their next publish
    /// goes out at once, and reloads the desktop without waiting.
    private var answering: [String: UUID] = [:]

    /// Called on the main thread with a widget id when its desktop widget's
    /// refresh button is pressed.
    var onRefreshRequest: ((String) -> Void)?

    /// Asks how many BarShelf desktop widgets are placed; answers on the
    /// main thread, nil when it could not tell.
    typealias PlacementProbe = (@escaping (Int?) -> Void) -> Void

    /// How often the placement is asked again. A widget placed in between
    /// shows its reading at the latest this long after.
    static let placementProbeInterval: TimeInterval = 5 * 60

    private let placementProbe: PlacementProbe?
    /// Desktop widgets placed when last asked; nil until known.
    private(set) var placedCount: Int?
    private var lastProbe: Date?
    private var probing = false
    /// The latest render of each widget, kept back while no desktop widget
    /// is placed, and written as soon as one is.
    private var held: [String: SharedShelf.Snapshot] = [:] {
        didSet { scheduleHeldProbe() }
    }
    /// Asks about placement again while renders are held, so a widget placed
    /// meanwhile gets them even if no new render arrives.
    private var heldProbe: DispatchWorkItem?
    /// Widgets flushed on first placement whose write is still on its way
    /// (thumbnails); the reload waits for the last of them.
    private var flushing: Set<String> = []
    /// Set while the flush is being started: the reload is its own then.
    private var flushStarting = false
    /// What was last written per widget, minus its time, and when it turns
    /// stale: an unchanged render is not written again until then.
    private var written: [String: (content: Data, staleAfter: Date?)] = [:]

    init(container: URL? = SharedShelfPublisher.entitledContainer(),
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: SharedShelf.widgetKind) },
         scheduleRefreshTimeout: @escaping (@escaping () -> Void) -> Void = { work in
             DispatchQueue.main.asyncAfter(deadline: .now() + SharedShelf.refreshRequestLifetime, execute: work)
         },
         placementProbe: PlacementProbe? = SharedShelfPublisher.defaultPlacementProbe()) {
        self.container = container
        self.reloadTimelines = reload
        self.scheduleRefreshTimeout = scheduleRefreshTimeout
        self.placementProbe = placementProbe
    }

    /// WidgetKit's list of placed widgets, in the app only (a test bundle has
    /// no widgets to ask about).
    static func defaultPlacementProbe() -> PlacementProbe? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return { answer in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let count = (try? result.get())?.filter { $0.kind == SharedShelf.widgetKind }.count
                DispatchQueue.main.async { answer(count) }
            }
        }
    }

    /// Asks WidgetKit again when the last answer is old.
    func refreshPlacementIfDue(now: Date = Date()) {
        guard let placementProbe, !probing else { return }
        if let lastProbe, now.timeIntervalSince(lastProbe) < Self.placementProbeInterval { return }
        probing = true
        lastProbe = now
        placementProbe { [weak self] count in
            self?.probing = false
            self?.placementChanged(to: count)
        }
    }

    /// A new answer. The first desktop widget placed gets every held render
    /// at once.
    func placementChanged(to count: Int?) {
        placedCount = count
        guard count ?? 1 > 0, !held.isEmpty else { return }
        let waiting = held
        held = [:]
        flushing = Set(waiting.keys)
        flushStarting = true
        for snapshot in waiting.values { publish(snapshot) }
        flushStarting = false
        // Widgets written at once are done; the reload goes out when the
        // last one with thumbnails is (`finishFlush`).
        if flushing.isEmpty { reloadNow() }
    }

    /// One flushed widget written or given up on; the last reloads.
    private func finishFlush(_ id: String) {
        guard flushing.remove(id) != nil, flushing.isEmpty, !flushStarting else { return }
        reloadNow()
    }

    /// A placement question is scheduled because renders are held (tests).
    var isWaitingToAskAgain: Bool { heldProbe != nil }

    private func scheduleHeldProbe() {
        guard placementProbe != nil, !held.isEmpty else {
            heldProbe?.cancel()
            heldProbe = nil
            return
        }
        guard heldProbe == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.heldProbe = nil
            self.refreshPlacementIfDue()
            self.scheduleHeldProbe()
        }
        heldProbe = item
        // When the next question is due, not a full interval from now: a
        // render may have asked a moment ago.
        let due = lastProbe.map { $0.addingTimeInterval(Self.placementProbeInterval).timeIntervalSinceNow }
            ?? Self.placementProbeInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, due), execute: item)
    }

    /// The snapshot as it would be written, without the times that change on
    /// every refresh.
    static func content(of snapshot: SharedShelf.Snapshot) -> Data? {
        var timeless = snapshot
        timeless.updatedAt = nil
        timeless.staleAfter = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(timeless)
    }

    /// Whether a render can be skipped: the same as the one written, and
    /// that one is not about to read as old on the desktop. One that shows
    /// files is never skipped: a file can change under the same path, and
    /// its thumbnail is only redone by writing.
    func isUnchanged(_ snapshot: SharedShelf.Snapshot, now: Date = Date()) -> Bool {
        guard Self.imagePaths(in: snapshot).isEmpty,
              let last = written[snapshot.widgetID], let content = Self.content(of: snapshot),
              content == last.content
        else { return false }
        guard let staleAfter = last.staleAfter else { return true }
        return staleAfter.timeIntervalSince(now) > Self.minimumReloadInterval
    }

    var isEnabled: Bool { container != nil }

    // MARK: - Refresh requests

    /// Starts listening for the extension's refresh button.
    func observeRefreshRequests() {
        guard container != nil else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let publisher = Unmanaged<SharedShelfPublisher>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { publisher.takeRefreshRequests() }
            },
            SharedShelf.refreshRequestNotification as CFString, nil, .deliverImmediately
        )
        takeRefreshRequests()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Reads the request files and hands each new one to the runtime. One
    /// that gets no answer — the widget failed, or is not offered — is
    /// dropped after the request lifetime so the widget stops saying
    /// "Refreshing".
    func takeRefreshRequests(now: Date = Date()) {
        guard let container else { return }
        let offered = Set(lastIndex?.entries.map(\.id) ?? [])
        for id in SharedShelf.pendingRefreshRequests(in: container, now: now).keys where answering[id] == nil {
            guard offered.contains(id) else {
                SharedShelf.clearRefreshRequest(widgetID: id, in: container)
                continue
            }
            let token = UUID()
            answering[id] = token
            onRefreshRequest?(id)
            scheduleRefreshTimeout { [weak self] in
                guard let self, self.answering[id] == token else { return }
                self.answering.removeValue(forKey: id)
                SharedShelf.clearRefreshRequest(widgetID: id, in: container)
                self.reloadNow()
            }
        }
    }

    /// Whether a widget's next render answers a desktop refresh request, so
    /// it should be published without the usual throttle.
    func isAnswering(_ widgetID: String) -> Bool {
        answering[widgetID] != nil
    }

    /// The list a user picks from when configuring a widget. Returns whether
    /// it changed.
    @discardableResult
    func publishIndex(_ entries: [SharedShelf.Entry]) -> Bool {
        guard let container else { return false }
        let index = SharedShelf.Index(entries: entries)
        guard index != lastIndex else { return false }
        let kept = Set(entries.map(\.id))
        let removed = Set(lastIndex?.entries.map(\.id) ?? []).subtracting(kept)
        for id in Set(exports.keys).subtracting(kept) {
            invalidate(id)
        }
        held = held.filter { kept.contains($0.key) }
        written = written.filter { kept.contains($0.key) }
        flushing.formIntersection(kept)
        do {
            try SharedShelf.writeIndex(index, to: container)
            SharedShelf.pruneSnapshots(keeping: kept, in: container)
            // Only once it is written: a failed write is tried again next time.
            lastIndex = index
            for id in removed {
                answering.removeValue(forKey: id)
                SharedShelf.clearRefreshRequest(widgetID: id, in: container)
            }
            // Removing the final candidate produces no later snapshot publish
            // to invalidate the extension's cached timeline.
            if !removed.isEmpty { reloadNow() }
        } catch {
            NSLog("barshelf: could not write the widget index: \(error)")
        }
        return true
    }

    func publish(_ snapshot: SharedShelf.Snapshot, now: Date = Date()) {
        guard let container else { return }
        let id = snapshot.widgetID
        if let lastIndex, !lastIndex.entries.contains(where: { $0.id == id }) { return }
        let asked = answering[id] != nil
        refreshPlacementIfDue(now: now)
        // Nobody has a BarShelf widget on the desktop: nothing to write or
        // reload until one is placed.
        if placedCount == 0, !asked {
            held[id] = snapshot
            return
        }
        // This render is the newest: nothing held may be written after it.
        held.removeValue(forKey: id)
        // The same reading as last time, still fresh on the desktop. Any
        // older render still exporting is dropped, so it can't land after.
        if !asked, isUnchanged(snapshot, now: now) {
            invalidate(id)
            finishFlush(id)
            return
        }
        let generation = invalidate(id)
        let paths = Self.imagePaths(in: snapshot)
        guard let folder = SharedShelf.imagesDirectory(for: id, in: container) else {
            finishFlush(id)
            return
        }
        guard !paths.isEmpty else {
            // Nothing to picture any more: no thumbnails left behind either.
            try? FileManager.default.removeItem(at: folder)
            write(Self.sharing(snapshot, thumbnails: [:]), to: container, source: snapshot)
            return
        }
        // Thumbnails first, then the snapshot that names them — unless the
        // widget was published again or taken out in the meantime.
        exports[id] = Task { @MainActor [weak self] in
            let thumbnails = await Self.exportThumbnails(paths, into: folder)
            guard let self, !Task.isCancelled, self.generations[id] == generation else { return }
            self.exports[id] = nil
            if let index = self.lastIndex, !index.entries.contains(where: { $0.id == id }) { return }
            self.write(Self.sharing(snapshot, thumbnails: thumbnails), to: container, source: snapshot)
        }
    }

    /// Cancels any export for the widget and makes older ones stale.
    @discardableResult
    private func invalidate(_ id: String) -> Int {
        exports.removeValue(forKey: id)?.cancel()
        let next = (generations[id] ?? 0) + 1
        generations[id] = next
        return next
    }

    /// Writes `snapshot` (as shared: scrubbed, with thumbnails) and remembers
    /// `source`, the render it came from, to tell an unchanged one next time.
    private func write(_ snapshot: SharedShelf.Snapshot, to container: URL, source: SharedShelf.Snapshot) {
        do {
            try SharedShelf.writeSnapshot(snapshot, to: container)
            if let content = Self.content(of: source) {
                written[source.widgetID] = (content, source.staleAfter)
            }
            if answering.removeValue(forKey: snapshot.widgetID) != nil {
                // The user pressed refresh on the desktop and is watching.
                SharedShelf.clearRefreshRequest(widgetID: snapshot.widgetID, in: container)
                flushing.remove(snapshot.widgetID)
                reloadNow()
                return
            }
            if flushing.contains(snapshot.widgetID) {
                finishFlush(snapshot.widgetID)
                return
            }
            scheduleReload()
        } catch {
            NSLog("barshelf: could not share \(snapshot.widgetID) with widgets: \(error)")
            finishFlush(snapshot.widgetID)
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
    /// their exported file, and no local file paths, actions, or drag
    /// payloads anywhere in it.
    static func sharing(_ snapshot: SharedShelf.Snapshot, thumbnails: [String: String]) -> SharedShelf.Snapshot {
        var shared = snapshot
        shared.viewTree = shared.viewTree.map(SharedShelf.scrubbed)
        for index in shared.parts.indices {
            shared.parts[index].node = SharedShelf.scrubbed(shared.parts[index].node)
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
            if Task.isCancelled { break }
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
        // A cancelled export leaves the folder to the one that replaced it.
        if Task.isCancelled { return names }
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
        invalidate(widgetID)
        held.removeValue(forKey: widgetID)
        written.removeValue(forKey: widgetID)
        flushing.remove(widgetID)
        answering.removeValue(forKey: widgetID)
        SharedShelf.clearRefreshRequest(widgetID: widgetID, in: container)
        SharedShelf.removeSnapshot(widgetID: widgetID, from: container)
        // Not left on the desktop until the reload window closes: this is
        // rare, and worth a reload from the daily budget.
        reloadNow()
    }

    /// Reloads widgets now, folding in any reload that was waiting.
    private func reloadNow() {
        pendingReload?.cancel()
        pendingReload = nil
        lastReload = Date()
        reloadTimelines()
    }

    private func scheduleReload(now: Date = Date()) {
        guard pendingReload == nil else { return }
        let wait = Self.reloadDelay(lastReload: lastReload, now: now)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            self.reloadTimelines()
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
