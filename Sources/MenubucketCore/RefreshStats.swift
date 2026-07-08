import Foundation

/// Per-widget refresh statistics shown in the app settings "Monitoring" tab
/// (R08): last refresh time, success/failure counts, average / most recent
/// duration, and the last error. Pure model — aggregation is unit-tested.
public struct WidgetRefreshStats: Codable, Equatable, Sendable {
    public var successCount: Int = 0
    public var failureCount: Int = 0
    /// Completion time of the most recent refresh (success or failure).
    public var lastRefreshAt: Date?
    /// Completion time of the most recent *successful* refresh.
    public var lastSuccessAt: Date?
    /// Duration of the most recent refresh that reported one (ms).
    public var lastDurationMs: Double?
    /// Running sum/count of reported durations (for the average).
    public var totalDurationMs: Double = 0
    public var durationSampleCount: Int = 0
    /// Message of the most recent failure; cleared by the next success.
    public var lastError: String?

    public init() {}

    public var totalCount: Int { successCount + failureCount }

    public var averageDurationMs: Double? {
        guard durationSampleCount > 0 else { return nil }
        return totalDurationMs / Double(durationSampleCount)
    }

    /// `nil` until the first refresh completes.
    public var lastOutcomeWasSuccess: Bool? {
        guard totalCount > 0 else { return nil }
        return lastError == nil
    }

    public mutating func recordSuccess(durationMs: Double?, at date: Date) {
        successCount += 1
        lastRefreshAt = date
        lastSuccessAt = date
        lastError = nil
        recordDuration(durationMs)
    }

    public mutating func recordFailure(
        error: String?, durationMs: Double?, at date: Date
    ) {
        failureCount += 1
        lastRefreshAt = date
        lastError = error ?? "unknown error"
        recordDuration(durationMs)
    }

    private mutating func recordDuration(_ durationMs: Double?) {
        guard let durationMs, durationMs.isFinite, durationMs >= 0 else { return }
        lastDurationMs = durationMs
        totalDurationMs += durationMs
        durationSampleCount += 1
    }
}

/// In-memory stats keyed by widget id, with a lightweight JSON persistence
/// ("메모리 + 간단 JSON 지속"): every record schedules a debounced best-effort
/// write, so stats survive relaunches without a write per refresh tick.
/// Thread-safe (`record*` may be called from any queue).
public final class RefreshStatsStore: @unchecked Sendable {
    public static let defaultFileName = "refresh-stats.json"

    private let lock = NSLock()
    private var statsByWidget: [String: WidgetRefreshStats]
    private let fileURL: URL?
    private let persistQueue = DispatchQueue(
        label: "dev.menubucket.refresh-stats", qos: .utility
    )
    private var pendingPersist: DispatchWorkItem?
    /// Debounce for disk writes; 0 (tests) persists synchronously.
    private let persistDebounce: TimeInterval

    public init(fileURL: URL? = nil, persistDebounce: TimeInterval = 2) {
        self.fileURL = fileURL
        self.persistDebounce = persistDebounce
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode(
               [String: WidgetRefreshStats].self, from: data
           ) {
            statsByWidget = decoded
        } else {
            statsByWidget = [:]
        }
    }

    // MARK: - Recording

    public func recordSuccess(
        widgetID: String, durationMs: Double? = nil, at date: Date = Date()
    ) {
        mutate(widgetID) { $0.recordSuccess(durationMs: durationMs, at: date) }
    }

    public func recordFailure(
        widgetID: String, error: String? = nil,
        durationMs: Double? = nil, at date: Date = Date()
    ) {
        mutate(widgetID) {
            $0.recordFailure(error: error, durationMs: durationMs, at: date)
        }
    }

    /// Drops stats of removed widgets (hot-reload cleanup).
    public func retain(widgetIDs: Set<String>) {
        lock.lock()
        let before = statsByWidget.count
        statsByWidget = statsByWidget.filter { widgetIDs.contains($0.key) }
        let changed = statsByWidget.count != before
        lock.unlock()
        if changed { schedulePersist() }
    }

    // MARK: - Reading

    public func stats(for widgetID: String) -> WidgetRefreshStats? {
        lock.lock()
        defer { lock.unlock() }
        return statsByWidget[widgetID]
    }

    public var all: [String: WidgetRefreshStats] {
        lock.lock()
        defer { lock.unlock() }
        return statsByWidget
    }

    // MARK: - Persistence

    private func mutate(
        _ widgetID: String, _ change: (inout WidgetRefreshStats) -> Void
    ) {
        lock.lock()
        var stats = statsByWidget[widgetID] ?? WidgetRefreshStats()
        change(&stats)
        statsByWidget[widgetID] = stats
        lock.unlock()
        schedulePersist()
    }

    private func schedulePersist() {
        guard fileURL != nil else { return }
        lock.lock()
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistNow() }
        pendingPersist = item
        lock.unlock()
        if persistDebounce <= 0 {
            persistQueue.sync(execute: item)
        } else {
            persistQueue.asyncAfter(
                deadline: .now() + persistDebounce, execute: item
            )
        }
    }

    /// Best-effort snapshot write (a lost trailing write only costs stats).
    private func persistNow() {
        guard let fileURL else { return }
        lock.lock()
        let snapshot = statsByWidget
        lock.unlock()
        do {
            let data = try Self.encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Stats are advisory; never fail a refresh over them.
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
