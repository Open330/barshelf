import Combine
import MenubucketCore

/// The last couple of minutes of each menu bar widget's reading, kept in
/// memory for the trend beside the reading in the card its menu bar item
/// opens. Nothing is measured for it: it records the readings the widgets
/// already report for the menu bar, one point per refresh.
final class ReadingHistory: ObservableObject {
    /// About two minutes at the 2 s refresh of a live meter.
    static let limit = 60

    @Published private(set) var values: [String: [Double]] = [:]

    /// The number a widget's menu bar reading is drawn from: its first
    /// metric with a machine-readable value.
    static func reading(of snapshot: WidgetSnapshot) -> Double? {
        snapshot.statusMetrics?.first { $0.number?.isFinite == true }?.number
    }

    func record(_ widgetID: String, _ value: Double) {
        var series = values[widgetID] ?? []
        series.append(value)
        if series.count > Self.limit { series.removeFirst(series.count - Self.limit) }
        values[widgetID] = series
    }

    func retain(_ widgetIDs: Set<String>) {
        guard values.keys.contains(where: { !widgetIDs.contains($0) }) else { return }
        values = values.filter { widgetIDs.contains($0.key) }
    }
}
