import Foundation

/// Keeps menu bar chart histories across a quit and relaunch.
///
/// Only a relaunch is bridged: histories saved more than `maxAge` ago are
/// dropped rather than joined onto new readings. Points are 5 s apart and a
/// graph shows about three minutes, so a longer gap drawn as a continuous
/// line would claim continuity it does not have. A missing or unreadable
/// file is simply no history.
public enum MenuBarChartHistoryStore {
    /// How often the running app saves — so the file a relaunch reads is
    /// never older than this plus the relaunch itself.
    public static let saveInterval: TimeInterval = 30
    public static let maxAge: TimeInterval = 60

    private struct File: Codable {
        var savedAt: Date
        var histories: [String: MenuBarChartHistory]
    }

    public static func save(_ histories: [String: MenuBarChartHistory], to url: URL, at now: Date = Date()) throws {
        guard !histories.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The unfinished step's peak becomes a point: a spike in the last
        // seconds before quitting would otherwise vanish.
        let flushed = histories.mapValues { history -> MenuBarChartHistory in
            var history = history
            if let pending = history.pending {
                history.values = Array((history.values + [pending]).suffix(MenuBarPolicy.chartHistoryLimit))
                history.pending = nil
            }
            return history
        }
        try JSONEncoder().encode(File(savedAt: now, histories: flushed)).write(to: url, options: .atomic)
    }

    public static func load(from url: URL, now: Date = Date()) -> [String: MenuBarChartHistory] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        let age = now.timeIntervalSince(file.savedAt)
        guard age >= 0, age <= maxAge else { return [:] }
        return file.histories.mapValues { history in
            var history = history
            history.values = Array(history.values.suffix(MenuBarPolicy.chartHistoryLimit))
            return history
        }
    }
}
