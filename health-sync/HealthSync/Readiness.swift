import Foundation
import HealthKit

/// Personal-baseline readiness signal, modelled on Whoop/Oura's overnight HRV
/// metric. One number, one sentence — that's the entire interaction surface.
/// We use HRV SDNN because it's the single most-validated autonomic-recovery
/// proxy and Apple Watch records it nightly without prompting.
struct ReadinessReading: Codable, Equatable {
    var todayHRV: Double?           // mean of last-night SDNN samples, ms
    var baselineHRV: Double?        // 7-day median of nightly means, ms
    var percentOfBaseline: Double?  // today / baseline. nil if either side missing
    var score: Int                  // 0…100, derived from percentOfBaseline
    var band: Band
    var advice: String
    var asOf: Date

    enum Band: String, Codable { case recovered, moderate, depleted, unknown }

    static let unknown = ReadinessReading(
        todayHRV: nil, baselineHRV: nil, percentOfBaseline: nil,
        score: 0, band: .unknown,
        advice: "Wear your watch for a few nights to calibrate.",
        asOf: Date()
    )
}

enum Readiness {

    /// Compute the reading from HealthKit.
    /// When 30-day series are available in the cache, uses the spec's weighted
    /// z-score formula: 0.4·z(HRV) − 0.3·z(RHR) + 0.3·z(sleep).
    /// Falls back to HRV-vs-baseline ratio when cache is absent.
    static func compute(store: HKHealthStore,
                        cache: [MetricKind: MetricSeries] = [:]) async -> ReadinessReading {
        let now = Date()

        // Weighted z-score path — requires ≥7 days in each series.
        if let hrvSeries  = cache[.hrv],  hrvSeries.history.count  >= 7,
           let rhrSeries  = cache[.rhr],  rhrSeries.history.count  >= 7,
           let sleepSeries = cache[.sleep], sleepSeries.history.count >= 7 {
            let hrvVals   = hrvSeries.history.map(\.value)
            let rhrVals   = rhrSeries.history.map(\.value)
            let sleepVals = sleepSeries.history.map(\.value)

            let zHRV   = zscore30(hrvVals)
            let zRHR   = zscore30(rhrVals)
            let zSleep = zscore30(sleepVals)

            let raw = 0.4 * zHRV - 0.3 * zRHR + 0.3 * zSleep
            // Normalise: raw ≈ ±1.5 in practice; map to [1, 100] around 50.
            let score = max(1, min(100, Int((50 + raw * 25).rounded())))

            let (band, advice): (ReadinessReading.Band, String) = {
                switch score {
                case ..<40:  return (.depleted,  "Run-down — your nervous system is asking for rest today.")
                case ..<65:  return (.moderate,  "Around baseline. Normal day, train as planned.")
                default:     return (.recovered, "Recovered. Push hard if you want to.")
                }
            }()

            let todayHRV = hrvVals.last
            let baseMean = hrvVals.dropLast().reduce(0, +) / Double(max(1, hrvVals.count - 1))
            let pct = todayHRV.map { $0 / baseMean }
            return ReadinessReading(todayHRV: todayHRV, baselineHRV: baseMean,
                                    percentOfBaseline: pct,
                                    score: score, band: band, advice: advice, asOf: now)
        }

        // Fallback: simple HRV-vs-7d-baseline ratio.
        async let today    = lastNightHRV(store: store, anchor: now)
        async let baseline = baselineHRV(store: store, days: 7, anchor: now)
        let t = await today
        let b = await baseline

        guard let t, let b, b > 0 else {
            var r = ReadinessReading.unknown
            r.todayHRV = t; r.baselineHRV = b; r.asOf = now
            return r
        }
        let pct = t / b
        let (band, advice): (ReadinessReading.Band, String) = {
            switch pct {
            case ..<0.85:  return (.depleted,  "Run-down — your nervous system is asking for rest today.")
            case ..<1.10:  return (.moderate,  "Around baseline. Normal day, train as planned.")
            default:       return (.recovered, "Recovered. Push hard if you want to.")
            }
        }()
        let score = max(0, min(100, Int((pct * 75).rounded())))
        return ReadinessReading(todayHRV: t, baselineHRV: b, percentOfBaseline: pct,
                                score: score, band: band, advice: advice, asOf: now)
    }

    // z-score of last value vs full window mean/stddev.
    private static func zscore30(_ xs: [Double]) -> Double {
        guard xs.count >= 2, let last = xs.last else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)
        let s = sqrt(v)
        return s > 0 ? (last - m) / s : 0
    }

    // MARK: - private HK queries

    /// Mean of HRV SDNN samples between yesterday-midnight and 10am-today (or now,
    /// whichever is earlier). Returns nil if no samples found.
    private static func lastNightHRV(store: HKHealthStore, anchor: Date) async -> Double? {
        guard let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: anchor)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let tenAM = cal.date(byAdding: .hour, value: 10, to: today)!
        let end = min(anchor, tenAM)
        guard end > yesterday else { return nil }
        return await meanSDNN(store: store, type: t, start: yesterday, end: end)
    }

    /// Median of the nightly-mean HRVs for the previous `days` nights, excluding
    /// the current night. Skips nights with no samples.
    private static func baselineHRV(store: HKHealthStore, days: Int, anchor: Date) async -> Double? {
        guard let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: anchor)
        var means: [Double] = []
        for i in 1...days {
            let nightEnd   = cal.date(byAdding: .day, value: -(i - 1), to: today)!
            let nightStart = cal.date(byAdding: .day, value: -i,       to: today)!
            if let m = await meanSDNN(store: store, type: t, start: nightStart, end: nightEnd) {
                means.append(m)
            }
        }
        return median(means)
    }

    private static func meanSDNN(store: HKHealthStore, type: HKQuantityType,
                                 start: Date, end: Date) async -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let unit = HKUnit.secondUnit(with: .milli)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let xs = samples as? [HKQuantitySample], !xs.isEmpty else {
                    cont.resume(returning: nil); return
                }
                let vals = xs.compactMap { s -> Double? in
                    guard s.quantity.is(compatibleWith: unit) else { return nil }
                    let v = s.quantity.doubleValue(for: unit)
                    return v.isFinite ? v : nil
                }
                guard !vals.isEmpty else { cont.resume(returning: nil); return }
                cont.resume(returning: vals.reduce(0, +) / Double(vals.count))
            }
            store.execute(q)
        }
    }

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
