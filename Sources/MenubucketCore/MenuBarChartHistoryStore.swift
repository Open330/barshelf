import Foundation

/// Keeps menu bar chart histories across a quit and relaunch.
///
/// Only a short absence is bridged: histories saved more than `maxAge` ago
/// are dropped rather than joined onto new readings — a line that runs
/// straight from last night into this morning claims continuity it does not
/// have. A missing or unreadable file is simply no history.
public enum MenuBarChartHistoryStore {
    public static let maxAge: TimeInterval = 10 * 60

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
        try JSONEncoder().encode(File(savedAt: now, histories: histories)).write(to: url, options: .atomic)
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
