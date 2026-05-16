import Foundation
import HealthKit

/// One daily-aggregated metric point.
struct MetricPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let value: Double
}

enum MetricKind: String, CaseIterable, Identifiable {
    case hrv   = "HRV"
    case rhr   = "Resting heart rate"
    case sleep = "Sleep"
    case steps = "Steps"

    var id: String { rawValue }

    var unitLabel: String {
        switch self {
        case .hrv:   return "ms"
        case .rhr:   return "bpm"
        case .sleep: return "h"
        case .steps: return ""
        }
    }
    var symbol: String {
        switch self {
        case .hrv:   return "waveform.path.ecg"
        case .rhr:   return "heart"
        case .sleep: return "moon"
        case .steps: return "figure.walk"
        }
    }
    /// Direction that is good. Used to colour the trend pill.
    var goodDirection: Direction {
        switch self {
        case .hrv, .sleep, .steps: return .up
        case .rhr:                  return .down
        }
    }
    enum Direction { case up, down }
}

/// History + Holt-smoothed level + forward forecast for one metric.
struct MetricSeries {
    let kind: MetricKind
    let history: [MetricPoint]
    let smoothed: [MetricPoint]
    let forecast: [MetricPoint]
    let trendPerDay: Double
}

enum TimeSeries {

    /// Pull daily history from HK and run Holt's exponential smoothing for a
    /// short-horizon forecast. The forecast is a *projection* of recent trend —
    /// it makes no claim about future events, just "if nothing changes…".
    static func compute(kind: MetricKind, days: Int = 30, forecastDays: Int = 7,
                        store: HKHealthStore) async -> MetricSeries {
        let history = await fetch(kind: kind, days: days, store: store)
        let values  = history.map { $0.value }
        guard let f = Forecaster.holt(values: values, periodsAhead: forecastDays) else {
            return MetricSeries(kind: kind, history: history, smoothed: [], forecast: [], trendPerDay: 0)
        }
        let smoothed = zip(history, f.smoothed).map { MetricPoint(date: $0.0.date, value: $0.1) }
        let cal = Calendar.current
        let lastDate = history.last?.date ?? Date()
        let forecast = f.forecast.enumerated().compactMap { i, v -> MetricPoint? in
            guard let d = cal.date(byAdding: .day, value: i + 1, to: lastDate) else { return nil }
            return MetricPoint(date: d, value: max(0, v))  // clip negatives — none of these can be < 0
        }
        return MetricSeries(kind: kind, history: history, smoothed: smoothed,
                            forecast: forecast, trendPerDay: f.trend)
    }

    // MARK: - HK fetchers (per metric, daily aggregation)

    private static func fetch(kind: MetricKind, days: Int, store: HKHealthStore) async -> [MetricPoint] {
        switch kind {
        case .hrv:
            guard let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return [] }
            return await statsByDay(type: t, unit: HKUnit.secondUnit(with: .milli),
                                    options: .discreteAverage, days: days, store: store)
        case .rhr:
            guard let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return [] }
            return await statsByDay(type: t, unit: HKUnit.count().unitDivided(by: .minute()),
                                    options: .discreteAverage, days: days, store: store)
        case .steps:
            guard let t = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
            return await statsByDay(type: t, unit: HKUnit.count(),
                                    options: .cumulativeSum, days: days, store: store)
        case .sleep:
            return await sleepByDay(days: days, store: store)
        }
    }

    private static func statsByDay(type: HKQuantityType, unit: HKUnit, options: HKStatisticsOptions,
                                   days: Int, store: HKHealthStore) async -> [MetricPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -days, to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let q = HKStatisticsCollectionQuery(quantityType: type,
                                            quantitySamplePredicate: predicate,
                                            options: options, anchorDate: start,
                                            intervalComponents: DateComponents(day: 1))
        return await withCheckedContinuation { cont in
            q.initialResultsHandler = { _, results, _ in
                var points: [MetricPoint] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let quantity: HKQuantity? = options.contains(.cumulativeSum)
                        ? stat.sumQuantity()
                        : stat.averageQuantity()
                    guard let q = quantity, q.is(compatibleWith: unit) else { return }
                    let v = q.doubleValue(for: unit)
                    guard v.isFinite, v > 0 else { return }
                    points.append(MetricPoint(date: stat.startDate, value: v))
                }
                cont.resume(returning: points)
            }
            store.execute(q)
        }
    }

    private static func sleepByDay(days: Int, store: HKHealthStore) async -> [MetricPoint] {
        guard let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -days, to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: today)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: t, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                // Apple Watch + Health app commonly report OVERLAPPING samples per
                // night: `asleepCore`, `asleepDeep`, `asleepREM`, `asleepUnspecified`
                // (and sometimes the legacy `asleep`) can all cover the same minutes.
                // Summing raw durations triples or quadruples the real value
                // (this is how "15.7 h slept" happens). Solution: collect intervals
                // per wake-day, then merge overlaps before summing.
                var intervalsByDay: [Date: [(start: Date, end: Date)]] = [:]
                for s in (samples as? [HKCategorySample]) ?? [] {
                    guard s.value != HKCategoryValueSleepAnalysis.inBed.rawValue,
                          s.value != HKCategoryValueSleepAnalysis.awake.rawValue,
                          s.endDate > s.startDate else { continue }
                    let day = cal.startOfDay(for: s.endDate)
                    intervalsByDay[day, default: []].append((s.startDate, s.endDate))
                }
                let points = intervalsByDay.keys.sorted().map { day -> MetricPoint in
                    let merged = mergeIntervals(intervalsByDay[day]!)
                    let total = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
                    return MetricPoint(date: day, value: total / 3600.0)
                }
                cont.resume(returning: points)
            }
            store.execute(q)
        }
    }

    /// Union overlapping (start, end) intervals. Returns disjoint intervals in
    /// chronological order.
    private static func mergeIntervals(_ xs: [(start: Date, end: Date)])
        -> [(start: Date, end: Date)] {
        guard !xs.isEmpty else { return [] }
        let sorted = xs.sorted { $0.start < $1.start }
        var out: [(start: Date, end: Date)] = [sorted[0]]
        for cur in sorted.dropFirst() {
            var last = out.removeLast()
            if cur.start <= last.end {
                last.end = max(last.end, cur.end)
                out.append(last)
            } else {
                out.append(last)
                out.append(cur)
            }
        }
        return out
    }
}

/// Holt's linear-trend exponential smoothing.
///
/// `level[t] = α·x[t] + (1-α)·(level[t-1] + trend[t-1])`
/// `trend[t] = β·(level[t] - level[t-1]) + (1-β)·trend[t-1]`
///
/// h-step-ahead forecast: `ŷ[n+h] = level[n] + h·trend[n]`.
///
/// This is the simplest principled forecaster for trended daily data with no
/// seasonality. Defaults α=0.3, β=0.1 are conservative — heavier weight on
/// the established level than on the latest noisy sample.
enum Forecaster {
    struct Result {
        let smoothed: [Double]
        let forecast: [Double]
        let trend: Double
    }
    static func holt(values: [Double], alpha: Double = 0.3, beta: Double = 0.1,
                     periodsAhead: Int = 7) -> Result? {
        guard values.count >= 2 else { return nil }
        var level = values[0]
        var trend = values[1] - values[0]
        var smoothed = [level]
        for i in 1..<values.count {
            let prevLevel = level
            level = alpha * values[i] + (1 - alpha) * (level + trend)
            trend = beta * (level - prevLevel) + (1 - beta) * trend
            smoothed.append(level)
        }
        // Guard: `1...0` is an invalid closed range. Models pass forecastDays=0
        // when they only need the smoothed level (no projection).
        let forecast: [Double] = periodsAhead > 0
            ? (1...periodsAhead).map { level + Double($0) * trend }
            : []
        return Result(smoothed: smoothed, forecast: forecast, trend: trend)
    }
}
