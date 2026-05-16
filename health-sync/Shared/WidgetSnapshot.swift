import Foundation

/// Compact `(date, value)` pair for widget sparklines. Codable so the whole
/// `WidgetSnapshot` round-trips through `JSONEncoder` cleanly.
struct MiniPoint: Codable, Equatable, Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
}

/// Snapshot shared between the iOS app and the widget extension via App Group
/// `UserDefaults`. The app writes after every meaningful sync; the widget reads
/// at every timeline refresh.
struct WidgetSnapshot: Codable, Equatable {
    var lastSyncDate: Date?
    var lastSampleCount: Int
    var totalSamplesLast24h: Int
    var serverReachable: Bool
    /// Daily readiness score (0–100). nil if not yet computed.
    var readinessScore: Int?
    /// Single-sentence summary, e.g. "Recovered. Push hard if you want to."
    var readinessAdvice: String?
    /// Raw band for tinting (recovered/moderate/depleted/unknown).
    var readinessBand: String?

    /// Last 30 days of daily values for the medium/large widget sparklines.
    /// Each `MiniPoint` is days-ago and value, so the widget needs no Date math.
    var hrvSeries:   [MiniPoint]
    var rhrSeries:   [MiniPoint]
    var sleepSeries: [MiniPoint]
    var stepsSeries: [MiniPoint]
    /// 7-day forecasts (positive `daysAhead`).
    var hrvForecast:   [MiniPoint]
    var rhrForecast:   [MiniPoint]
    var sleepForecast: [MiniPoint]
    var stepsForecast: [MiniPoint]

    static let empty = WidgetSnapshot(
        lastSyncDate: nil,
        lastSampleCount: 0,
        totalSamplesLast24h: 0,
        serverReachable: false,
        readinessScore: nil,
        readinessAdvice: nil,
        readinessBand: nil,
        hrvSeries: [], rhrSeries: [], sleepSeries: [], stepsSeries: [],
        hrvForecast: [], rhrForecast: [], sleepForecast: [], stepsForecast: []
    )

    /// Older than 30 min = "stale". Drives the warning state in the widget.
    var isStale: Bool {
        guard let d = lastSyncDate else { return true }
        return Date().timeIntervalSince(d) > 30 * 60
    }
}

enum WidgetStore {
    static let appGroup = "group.io.vulturelabs.healthsyncs"
    private static let key = "widget_snapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let d = defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        d.set(data, forKey: key)
    }

    static func read() -> WidgetSnapshot {
        guard let d = defaults,
              let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return s
    }
}
