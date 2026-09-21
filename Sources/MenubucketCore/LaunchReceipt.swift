import Foundation

/// A record the app writes once it is genuinely running, so an updater can tell
/// a live build from a corpse.
///
/// `pgrep` is not enough, and this is not hypothetical: after an in-place
/// update on macOS 27 the replaced app launched into a process that existed,
/// held its pid, and never ran — 32 KB resident, parked in `_dyld_start`,
/// refused by the kernel's AppleSystemPolicy. The updater reported success,
/// quit the old build, and left the machine with no BarShelf at all. It stayed
/// that way for a day because nothing checked.
///
/// The receipt is written *after* the status item exists, so it attests to the
/// thing the user would look for — an icon in the menu bar — rather than to
/// mere process creation.
public struct LaunchReceipt: Codable, Equatable, Sendable {
    public var version: String?
    public var pid: Int32
    public var bootedAt: Date
    public var bundlePath: String?

    public init(version: String?, pid: Int32, bootedAt: Date, bundlePath: String?) {
        self.version = version
        self.pid = pid
        self.bootedAt = bootedAt
        self.bundlePath = bundlePath
    }
}

public enum LaunchReceiptStore {
    /// `~/Library/Application Support/barshelf/launch-receipt.json`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("barshelf", isDirectory: true)
            .appendingPathComponent("launch-receipt.json")
    }

    /// How long an updater waits for the replacement to announce itself. Long
    /// enough for a cold start on a slow disk, short enough that a user staring
    /// at a progress panel does not conclude it has hung.
    public static let defaultTimeout: TimeInterval = 20

    @discardableResult
    public static func write(
        version: String?,
        bundlePath: String?,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        at date: Date = Date(),
        to url: URL = defaultURL
    ) -> LaunchReceipt? {
        // Truncated to whole seconds to match what ISO-8601 encoding keeps.
        // Without this the receipt handed back here never equals the one read
        // from disk, and every wait would accept the *old* receipt as proof
        // that the replacement had started — the exact failure this exists to
        // catch, reintroduced by a rounding difference.
        let receipt = LaunchReceipt(
            version: version,
            pid: pid,
            bootedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)),
            bundlePath: bundlePath
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(receipt).write(to: url, options: .atomic)
        } catch {
            // Never fail a launch over bookkeeping. A missing receipt makes an
            // updater report "did not start", which is the safe direction: it
            // leaves the old build running rather than quitting into nothing.
            return nil
        }
        return receipt
    }

    public static func read(from url: URL = defaultURL) -> LaunchReceipt? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LaunchReceipt.self, from: data)
    }

    /// Blocks until a receipt appears that is not `previous`, or the timeout
    /// expires.
    ///
    /// Compared against the receipt read *before* relaunching rather than
    /// against a timestamp: a clock that steps backwards between the two reads
    /// would otherwise make a real launch look like it never happened.
    public static func waitForRelaunch(
        replacing previous: LaunchReceipt?,
        timeout: TimeInterval = defaultTimeout,
        pollInterval: TimeInterval = 0.25,
        url: URL = defaultURL,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> LaunchReceipt? {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            if let current = read(from: url), current != previous {
                return current
            }
            guard now() < deadline else { return nil }
            sleep(pollInterval)
        }
    }
}
