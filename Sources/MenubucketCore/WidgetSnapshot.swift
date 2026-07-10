import Foundation

/// Per-widget runtime state, including the last-good render.
///
/// Invariant: `viewTree` holds the most recent *successful* render and is never
/// cleared by a failure — failures only set `error` (rendered as a banner over
/// the cached tree). The snapshot (minus transient `isLoading`) serializes to
/// JSON for the on-disk render cache.
public struct WidgetSnapshot: Codable, Equatable {
    public var widgetID: String
    /// Last successful view tree ("UI never blanks").
    public var viewTree: UINode?
    /// When `viewTree` was last successfully produced.
    public var updatedAt: Date?
    /// Latest failure message, if the most recent refresh failed.
    public var error: String?
    /// True only for a widget-supplied, explicitly redacted fallback tree.
    /// Optional so caches written before this field existed still decode.
    public var safeForSensitiveCache: Bool?
    /// Transient — not persisted.
    public var isLoading: Bool = false

    private enum CodingKeys: String, CodingKey {
        case widgetID, viewTree, updatedAt, error, safeForSensitiveCache
    }

    public init(
        widgetID: String,
        viewTree: UINode? = nil,
        updatedAt: Date? = nil,
        error: String? = nil,
        safeForSensitiveCache: Bool? = nil,
        isLoading: Bool = false
    ) {
        self.widgetID = widgetID
        self.viewTree = viewTree
        self.updatedAt = updatedAt
        self.error = error
        self.safeForSensitiveCache = safeForSensitiveCache
        self.isLoading = isLoading
    }

    /// True when a refresh should run given the widget's staleness policy.
    /// `nil` staleAfterSec means "always stale" (refresh every trigger).
    public func isStale(after staleAfterSec: Double?, now: Date = Date()) -> Bool {
        guard let updatedAt else { return true }
        guard let staleAfterSec else { return true }
        return now.timeIntervalSince(updatedAt) > staleAfterSec
    }

    // MARK: - Render cache serialization

    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func deserialize(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
        snapshot.isLoading = false
        return snapshot
    }
}
