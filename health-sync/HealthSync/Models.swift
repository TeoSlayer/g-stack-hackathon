import Foundation
import HealthKit

// MARK: - Shared types

/// Universal output for every model card. Each model fills in what's relevant
/// and the view renders the same layout for all of them.
struct ModelReading: Identifiable {
    let id: ModelKind
    let title: String
    let valueText: String        // big number / label, e.g. "78" or "2.3 h"
    let band: Band               // colour bucket
    let action: String           // one-sentence "what to do about it"
    let detail: String           // small grey caption
    let series: [MetricPoint]    // optional 30-day history for inline chart
    let smoothed: [MetricPoint]  // optional smoothed overlay (Kalman, etc.)

    init(id: ModelKind, title: String, valueText: String, band: Band,
         action: String, detail: String = "",
         series: [MetricPoint] = [], smoothed: [MetricPoint] = []) {
        self.id = id; self.title = title; self.valueText = valueText
        self.band = band; self.action = action; self.detail = detail
        self.series = series; self.smoothed = smoothed
    }
}

enum Band: String {
    case good, ok, warn, bad, unknown
}

enum ModelKind: String, CaseIterable, Identifiable {
    // Original 7
    case sleepRegularity, autonomicBalance, sedentaryStress
    case cognitiveDebt, burnoutCUSUM, bedtimeDrift, kalmanHRV
    // Spec metrics — Tier 1 (autonomic)
    case rrDeviation, vagalRebound, rhrSlope, morningSurge, acwr, hrvCV
    // Spec metrics — Tier 2 (sleep precision)
    case sleepEfficiency, waso, solSpike, socialJetlag
    // Spec metrics — Tier 3 (metabolic / behavioral)
    case spO2Density, acousticLoad, lightDeficit, sedentaryFrag
    case bodyMassVolatility, vo2Trend, burnoutVelocity
    case trainingMonotony, rhrDip, neat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sleepRegularity:    return "Sleep Regularity Index"
        case .autonomicBalance:   return "Autonomic Balance"
        case .sedentaryStress:    return "Sedentary Stress"
        case .cognitiveDebt:      return "Cognitive Recovery Debt"
        case .burnoutCUSUM:       return "Burnout Early Warning"
        case .bedtimeDrift:       return "Circadian Drift"
        case .kalmanHRV:          return "HRV (Kalman-smoothed)"
        case .rrDeviation:        return "Respiratory Rate Deviation"
        case .vagalRebound:       return "Vagal Tone Rebound"
        case .rhrSlope:           return "RHR Trajectory"
        case .morningSurge:       return "Morning HR Surge"
        case .acwr:               return "Workload Ratio (ACWR)"
        case .hrvCV:              return "HRV Stability"
        case .sleepEfficiency:    return "Sleep Architecture Efficiency"
        case .waso:               return "Wakefulness After Sleep Onset"
        case .solSpike:           return "Sleep Onset Latency"
        case .socialJetlag:       return "Social Jetlag"
        case .spO2Density:        return "SpO2 Desaturation Density"
        case .acousticLoad:       return "Acoustic Load"
        case .lightDeficit:       return "Light Deficit"
        case .sedentaryFrag:      return "Movement Rate"
        case .bodyMassVolatility: return "Body Mass Stability"
        case .vo2Trend:           return "VO2 Max Trend"
        case .burnoutVelocity:    return "Burnout Velocity"
        case .trainingMonotony:   return "Training Monotony"
        case .rhrDip:             return "Nocturnal HR Dip"
        case .neat:               return "Non-Exercise Activity (NEAT)"
        }
    }
    var citation: String {
        switch self {
        case .sleepRegularity:    return "Phillips et al."
        case .autonomicBalance:   return "Composite z-score"
        case .sedentaryStress:    return "Castaldo et al."
        case .cognitiveDebt:      return "Sleep-debt accumulator"
        case .burnoutCUSUM:       return "Page / Shewhart control chart"
        case .bedtimeDrift:       return "Mann-Kendall trend test"
        case .kalmanHRV:          return "Local-level state-space"
        case .rrDeviation:        return "EWMA acute vs chronic"
        case .vagalRebound:       return "Pre/post-sleep HRV delta"
        case .rhrSlope:           return "7-day linear regression"
        case .morningSurge:       return "Orthostatic HR proxy"
        case .acwr:               return "Gabbett et al."
        case .hrvCV:              return "ANS stability ratio"
        case .sleepEfficiency:    return "AASM deep+REM / in-bed"
        case .waso:               return "PSG standard"
        case .solSpike:           return "30-day z-score"
        case .socialJetlag:       return "Roenneberg et al."
        case .spO2Density:        return "Apnea proxy (AASM)"
        case .acousticLoad:       return "NIOSH dose metric"
        case .lightDeficit:       return "Leproult et al."
        case .sedentaryFrag:      return "Stand events / awake hour"
        case .bodyMassVolatility: return "7-day stddev"
        case .vo2Trend:           return "30-day derivative"
        case .burnoutVelocity:    return "Composite slope"
        case .trainingMonotony:   return "Foster et al."
        case .rhrDip:             return "Nocturnal dipping ratio"
        case .neat:               return "Levine et al."
        }
    }
}

// MARK: - Entry point

enum Models {
    /// Compute every model in parallel. Pass `cache` (the manager's `cachedSeries`)
    /// so the 5 models that need HRV/RHR/Sleep skip a redundant HK round-trip.
    static func computeAll(store: HKHealthStore,
                           cache: [MetricKind: MetricSeries] = [:]) async -> [ModelReading] {
        // Original 7
        async let sri   = sleepRegularityIndex(store: store)
        async let abal  = autonomicBalance(store: store, cache: cache)
        async let sed   = sedentaryStress(store: store, cache: cache)
        async let debt  = cognitiveRecoveryDebt(store: store, cache: cache)
        async let cusum = burnoutCUSUM(store: store, cache: cache)
        async let mk    = bedtimeDrift(store: store)
        async let kal   = kalmanHRV(store: store, cache: cache)
        // Tier 1 — autonomic
        async let rrDev  = rrDeviation(store: store)
        async let vagal  = vagalRebound(store: store)
        async let rhrSl  = rhrSlopeMetric(store: store, cache: cache)
        async let surge  = morningSurge(store: store)
        async let acwrR  = acwrMetric(store: store)
        async let hrvcv  = hrvCVMetric(store: store, cache: cache)
        // Tier 2 — sleep precision
        async let slEff  = sleepEfficiencyMetric(store: store)
        async let wasoR  = wasoMetric(store: store)
        async let solSp  = solSpikeMetric(store: store)
        async let sji    = socialJetlagMetric(store: store)
        // Tier 3 — metabolic / behavioral
        async let spo2   = spO2DensityMetric(store: store)
        async let acous  = acousticLoadMetric(store: store)
        async let light  = lightDeficitMetric(store: store)
        async let sfr    = sedentaryFragMetric(store: store)
        async let bmVol  = bodyMassVolatilityMetric(store: store)
        async let vo2tr  = vo2TrendMetric(store: store)
        async let bVel   = burnoutVelocityMetric(store: store, cache: cache)
        async let mono   = trainingMonotony(store: store)
        async let rDip   = rhrDipAmplitude(store: store)
        async let neatR  = neatProxy(store: store)
        return await [
            sri, abal, sed, debt, cusum, mk, kal,
            rrDev, vagal, rhrSl, surge, acwrR, hrvcv,
            slEff, wasoR, solSp, sji,
            spo2, acous, light, sfr, bmVol, vo2tr, bVel,
            mono, rDip, neatR
        ]
    }

    /// Read a series from the cache, fall back to a fresh HK query if absent.
    static func seriesOrFetch(_ kind: MetricKind, days: Int,
                                          cache: [MetricKind: MetricSeries],
                                          store: HKHealthStore) async -> MetricSeries {
        if let cached = cache[kind], cached.history.count >= 3 {
            return cached
        }
        return await TimeSeries.compute(kind: kind, days: days, forecastDays: 0, store: store)
    }
}

// MARK: - 1. Sleep Regularity Index (Phillips et al.)

/// Pairwise probability of being in the same sleep/wake state at the same
/// minute-of-day across every pair of days in a 14-day window. Ranges 0–100,
/// where 100 = perfectly regular (you're always asleep at the same minutes).
///
/// The single best non-duration sleep metric — Phillips et al. found it
/// outperforms total sleep duration for predicting cognitive performance
/// and mood. Doesn't punish naps or weekend lie-ins; punishes *inconsistency*.
extension Models {
    static func sleepRegularityIndex(store: HKHealthStore) async -> ModelReading {
        let days = 14
        guard let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return ModelReading(id: .sleepRegularity, title: ModelKind.sleepRegularity.displayName,
                                valueText: "—", band: .unknown,
                                action: "Sleep data unavailable on this device.", detail: "")
        }
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -days, to: end)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: t, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        // Skip "in bed" envelopes — sleep stages and "asleep" carry the signal.
        let asleep = samples.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }

        // Compute off-main: build a [days × 1440] state matrix of asleep/awake.
        let sri: Double? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var matrix = Array(repeating: Array(repeating: false, count: 1440), count: days)
                for s in asleep {
                    let begin = max(s.startDate, start)
                    let finish = min(s.endDate, end)
                    if finish <= begin { continue }
                    // Iterate minute boundaries
                    var cursor = begin
                    while cursor < finish {
                        let diff = cal.dateComponents([.day, .minute], from: start, to: cursor)
                        let dayIdx = diff.day ?? 0
                        let dayStart = cal.date(byAdding: .day, value: dayIdx, to: start)!
                        let minOfDay = Int(cursor.timeIntervalSince(dayStart) / 60.0)
                        if dayIdx >= 0 && dayIdx < days && minOfDay >= 0 && minOfDay < 1440 {
                            matrix[dayIdx][minOfDay] = true
                        }
                        cursor = cursor.addingTimeInterval(60)
                    }
                }
                // Pairwise agreement: SRI = 100 × P(same state at same minute across day-pairs)
                var agree = 0
                var total = 0
                for i in 0..<days {
                    for j in (i + 1)..<days {
                        for m in 0..<1440 {
                            if matrix[i][m] == matrix[j][m] { agree += 1 }
                            total += 1
                        }
                    }
                }
                guard total > 0 else { cont.resume(returning: nil); return }
                cont.resume(returning: 100.0 * Double(agree) / Double(total))
            }
        }

        guard let value = sri else {
            return ModelReading(id: .sleepRegularity, title: ModelKind.sleepRegularity.displayName,
                                valueText: "—", band: .unknown,
                                action: "Wear your watch overnight for a couple of weeks to calibrate.",
                                detail: ModelKind.sleepRegularity.citation)
        }
        let band: Band
        let action: String
        switch value {
        case ..<60:  (band, action) = (.bad,  "Wildly irregular sleep — pick a fixed bedtime and hold it for a week.")
        case ..<75:  (band, action) = (.warn, "Inconsistent sleep timing. Aim to be in bed at the same hour ±30 min.")
        case ..<85:  (band, action) = (.ok,   "Reasonably regular. Tighten the bedtime window for a cognition boost.")
        default:      (band, action) = (.good, "Excellent sleep regularity. Keep this rhythm.")
        }
        return ModelReading(id: .sleepRegularity, title: ModelKind.sleepRegularity.displayName,
                            valueText: String(format: "%.0f / 100", value),
                            band: band, action: action,
                            detail: "\(days)-day window · \(ModelKind.sleepRegularity.citation)")
    }
}

// MARK: - 2. Autonomic Balance (HRV/RHR composite z-score)

extension Models {
    static func autonomicBalance(store: HKHealthStore,
                                 cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        async let hrv = seriesOrFetch(.hrv, days: 14, cache: cache, store: store)
        async let rhr = seriesOrFetch(.rhr, days: 14, cache: cache, store: store)
        let (h, r) = await (hrv, rhr)
        guard h.history.count >= 5, r.history.count >= 5 else {
            return ModelReading(id: .autonomicBalance, title: ModelKind.autonomicBalance.displayName,
                                valueText: "—", band: .unknown,
                                action: "Not enough HRV/RHR data yet.",
                                detail: "Need 5+ days of each")
        }
        let zH = zscore(h.history.map(\.value))
        let zR = zscore(r.history.map(\.value))
        // HRV up = good, RHR up = bad. Subtract to align direction.
        let score = (zH ?? 0) - (zR ?? 0)
        let band: Band
        let action: String
        switch score {
        case ..<(-1.0): (band, action) = (.bad,  "Both signals moving the wrong way. Reduce load, prioritize sleep.")
        case ..<(-0.3): (band, action) = (.warn, "Mild stress accumulating. Easy day.")
        case ..<0.3:    (band, action) = (.ok,   "Around baseline.")
        case ..<1.0:    (band, action) = (.good, "Recovering well.")
        default:         (band, action) = (.good, "Strong recovery state.")
        }
        return ModelReading(id: .autonomicBalance, title: ModelKind.autonomicBalance.displayName,
                            valueText: String(format: "%+.2f σ", score),
                            band: band, action: action,
                            detail: "z(HRV) − z(RHR) · 14d window")
    }
}

// MARK: - 3. Sedentary Stress Index

/// Minutes today where HR > (RHR_baseline + 20) while step count for that hour
/// is < 200 — i.e. you're sitting still but your heart isn't. Captures the
/// "anxious at desk for hours" load that physical-training models completely miss.
extension Models {
    static func sedentaryStress(store: HKHealthStore,
                                cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        async let hrSeries    = hourlyMeanHR(store: store, hoursBack: 24)
        async let stepsSeries = hourlyTotalSteps(store: store, hoursBack: 24)
        async let rhrSeries   = seriesOrFetch(.rhr, days: 14, cache: cache, store: store)
        let (hr, st, rhrS) = await (hrSeries, stepsSeries, rhrSeries)
        let baseline = mean(of: rhrS.history.map(\.value))
        guard let baseline, !hr.isEmpty else {
            return ModelReading(id: .sedentaryStress, title: ModelKind.sedentaryStress.displayName,
                                valueText: "—", band: .unknown,
                                action: "Need ~14 days of resting-HR data and recent hourly HR.",
                                detail: ModelKind.sedentaryStress.citation)
        }
        let threshold = baseline + 20
        var stressMins = 0
        // Iterate hourly buckets; each "stressed hour" contributes 60 minutes worst-case.
        // More accurate would be per-minute HR, but per-hour mean is the cheap honest version.
        let stepsByHour = Dictionary(uniqueKeysWithValues: st.map { ($0.date, $0.value) })
        for hour in hr {
            let steps = stepsByHour[hour.date] ?? 0
            if steps < 200 && hour.value > threshold { stressMins += 60 }
        }
        let band: Band
        let action: String
        switch stressMins {
        case 0...60:   (band, action) = (.good, "Calm at rest today.")
        case 61...180: (band, action) = (.ok,   "Some anxious-at-desk time. A walk or 5 min of breath work would reset it.")
        case 181...300:(band, action) = (.warn, "You sat tense for hours. Stand up, move outside, do box breathing.")
        default:        (band, action) = (.bad,  "Sustained sedentary stress. Stop, walk, breathe — your body's in fight-or-flight.")
        }
        return ModelReading(id: .sedentaryStress, title: ModelKind.sedentaryStress.displayName,
                            valueText: "\(stressMins) min today",
                            band: band, action: action,
                            detail: String(format: "HR > %.0f bpm, steps < 200 · last 24h", threshold))
    }
}

// MARK: - 4. Cognitive Recovery Debt

extension Models {
    static func cognitiveRecoveryDebt(store: HKHealthStore,
                                      cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        let sleepFull = await seriesOrFetch(.sleep, days: 7, cache: cache, store: store)
        // 7-day window even if cache is 30-day.
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let sleep = MetricSeries(kind: .sleep,
                                 history: sleepFull.history.filter { $0.date >= cutoff },
                                 smoothed: [], forecast: [], trendPerDay: 0)
        guard sleep.history.count >= 3 else {
            return ModelReading(id: .cognitiveDebt, title: ModelKind.cognitiveDebt.displayName,
                                valueText: "—", band: .unknown,
                                action: "Need 3+ nights of sleep data.",
                                detail: "Need ≥3 nights")
        }
        let need = 8.0  // hours; could later be user-tunable
        // Exponentially-weighted debt — recent nights count more.
        var total = 0.0
        var weights = 0.0
        for (i, point) in sleep.history.enumerated() {
            let daysAgo = sleep.history.count - 1 - i  // 0 = most recent
            let w = exp(-Double(daysAgo) / 3.0)
            let nightDebt = max(0, need - point.value)
            total += w * nightDebt
            weights += w
        }
        let normalized = weights > 0 ? total / weights * Double(sleep.history.count) : 0
        let band: Band
        let action: String
        switch normalized {
        case ..<3:   (band, action) = (.good, "Sleep debt is manageable.")
        case ..<6:   (band, action) = (.ok,   "Building debt. Try one earlier night this week.")
        case ..<10:  (band, action) = (.warn, "Significant debt. You need a recovery night, not coffee.")
        default:      (band, action) = (.bad,  "Severe sleep debt — cognition is measurably impaired right now.")
        }
        return ModelReading(id: .cognitiveDebt, title: ModelKind.cognitiveDebt.displayName,
                            valueText: String(format: "%.1f h", normalized),
                            band: band, action: action,
                            detail: "EWMA of (8h − actual) over last \(sleep.history.count) nights",
                            series: sleep.history)
    }
}

// MARK: - 5. Burnout CUSUM on RHR

/// CUSUM (Page-Shewhart control chart) for shift detection on resting-HR. Chronic stress shifts
/// baseline RHR upward 2–5 bpm weeks before subjective burnout. CUSUM is the
/// standard outbreak-detection statistic in epidemiology; same math applies
/// to "outbreak of stress in this human."
extension Models {
    static func burnoutCUSUM(store: HKHealthStore,
                             cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        // CUSUM ideally wants 60 days; the cache only has 30. Use the cache if
        // present (still computable), otherwise fetch 60 fresh.
        let r: MetricSeries
        if let c = cache[.rhr], c.history.count >= 14 {
            r = c
        } else {
            r = await TimeSeries.compute(kind: .rhr, days: 60, forecastDays: 0, store: store)
        }
        let vals = r.history.map(\.value)
        guard vals.count >= 14 else {
            return ModelReading(id: .burnoutCUSUM, title: ModelKind.burnoutCUSUM.displayName,
                                valueText: "—", band: .unknown,
                                action: "Need 14+ days of resting-HR data.",
                                detail: ModelKind.burnoutCUSUM.citation)
        }
        // Reference period: first half of history. Detection period: second half.
        let refSize = vals.count / 2
        let ref = Array(vals.prefix(refSize))
        let mu = ref.reduce(0, +) / Double(ref.count)
        let sd = stddev(ref) ?? 1
        let k = 0.5 * sd
        let h = 5.0 * sd

        var cusum = 0.0
        var peak = 0.0
        var triggeredAt: Int? = nil
        for (idx, v) in vals.enumerated() where idx >= refSize {
            cusum = max(0, cusum + (v - mu - k))
            peak = max(peak, cusum)
            if cusum > h && triggeredAt == nil {
                triggeredAt = idx
            }
        }
        let alarm = peak > h
        let band: Band = alarm ? .bad : (peak > h * 0.6 ? .warn : .good)
        let action: String = alarm
            ? "RHR has drifted up vs your baseline — early burnout / overtraining signal. Pull back load this week."
            : (peak > h * 0.6
               ? "RHR creeping up. Watch for further drift over the next few days."
               : "RHR stable vs baseline. No drift detected.")
        return ModelReading(id: .burnoutCUSUM, title: ModelKind.burnoutCUSUM.displayName,
                            valueText: alarm ? "ALARM" : "stable",
                            band: band, action: action,
                            detail: String(format: "CUSUM peak %.2f vs threshold %.2f · \(ModelKind.burnoutCUSUM.citation)", peak, h),
                            series: r.history)
    }
}

// MARK: - 6. Circadian Drift (Mann-Kendall on bedtime)

/// Non-parametric trend test on the per-night bedtime over 14 days. Reports
/// the two-sided p-value plus an interpretation. Mann-Kendall is robust to
/// outliers (one wild night doesn't dominate) and assumes nothing about
/// distribution. Standard in environmental science / epidemiology.
extension Models {
    static func bedtimeDrift(store: HKHealthStore) async -> ModelReading {
        let bedtimes = await fetchNightlyBedtimes(store: store, days: 14)
        guard bedtimes.count >= 7 else {
            return ModelReading(id: .bedtimeDrift, title: ModelKind.bedtimeDrift.displayName,
                                valueText: "—", band: .unknown,
                                action: "Need at least a week of recorded sleep starts.",
                                detail: ModelKind.bedtimeDrift.citation)
        }
        let xs = bedtimes.map(\.value)  // minutes past midnight (handling rollover below)
        let (s, p, dir) = mannKendall(xs)
        let band: Band
        let action: String
        if p < 0.05 && dir > 0 {
            (band, action) = (.warn, "Bedtime is drifting later — anchor a fixed lights-out time before this becomes weeks of bad sleep.")
        } else if p < 0.05 && dir < 0 {
            (band, action) = (.good, "Bedtime drifting earlier — keep going.")
        } else if p < 0.15 && dir > 0 {
            (band, action) = (.ok, "Mild drift later — watch it.")
        } else {
            (band, action) = (.good, "Bedtime is stable.")
        }
        let dirText = dir > 0 ? "later" : (dir < 0 ? "earlier" : "flat")
        return ModelReading(id: .bedtimeDrift, title: ModelKind.bedtimeDrift.displayName,
                            valueText: String(format: "p = %.3f (%@)", p, dirText as CVarArg),
                            band: band, action: action,
                            detail: "Mann-Kendall on \(bedtimes.count) nights · S=\(s)",
                            series: bedtimes)
    }
}

// MARK: - 7. Kalman-smoothed HRV

/// Local-level state-space model. The state μ is your "true" current HRV;
/// each observation y_t is μ + noise. Online Kalman update gives you the
/// smoothest available current-value estimate with a confidence band as a
/// free by-product. Better than Holt for non-trended noisy data.
extension Models {
    static func kalmanHRV(store: HKHealthStore,
                          cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        let h = await seriesOrFetch(.hrv, days: 30, cache: cache, store: store)
        let vals = h.history.map(\.value)
        guard vals.count >= 5 else {
            return ModelReading(id: .kalmanHRV, title: ModelKind.kalmanHRV.displayName,
                                valueText: "—", band: .unknown,
                                action: "Need ~5 days of HRV data.",
                                detail: ModelKind.kalmanHRV.citation)
        }
        let smoothed = kalmanLocalLevel(values: vals)
        let estimate = smoothed.last ?? 0
        let last = vals.last ?? 0
        let band: Band = last > estimate * 1.05 ? .good : (last < estimate * 0.9 ? .warn : .ok)
        let action: String = last < estimate * 0.9
            ? "Today's HRV is below your smoothed trend. Easy day."
            : "Today's HRV is in line with your trend."
        let history = zip(h.history, smoothed).map { MetricPoint(date: $0.0.date, value: $0.1) }
        return ModelReading(id: .kalmanHRV, title: ModelKind.kalmanHRV.displayName,
                            valueText: String(format: "%.0f ms", estimate),
                            band: band, action: action,
                            detail: "Local-level Kalman · \(vals.count) days · \(ModelKind.kalmanHRV.citation)",
                            series: h.history, smoothed: history)
    }
}

// MARK: - Math primitives

func zscore(_ xs: [Double]) -> Double? {
    guard xs.count >= 2 else { return nil }
    let m = xs.reduce(0, +) / Double(xs.count)
    let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)
    let s = sqrt(v)
    guard s > 0, let last = xs.last else { return nil }
    return (last - m) / s
}

func stddev(_ xs: [Double]) -> Double? {
    guard xs.count >= 2 else { return nil }
    let m = xs.reduce(0, +) / Double(xs.count)
    let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)
    return sqrt(v)
}

func mean(of xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    return xs.reduce(0, +) / Double(xs.count)
}

/// Mann-Kendall trend test. Returns (S, two-sided p, direction sign).
/// Direction: +1 trending up, -1 trending down, 0 flat.
private func mannKendall(_ xs: [Double]) -> (Int, Double, Int) {
    let n = xs.count
    var s = 0
    for i in 0..<(n - 1) {
        for j in (i + 1)..<n {
            if xs[j] > xs[i] { s += 1 }
            else if xs[j] < xs[i] { s -= 1 }
        }
    }
    let varS = Double(n * (n - 1) * (2 * n + 5)) / 18.0
    guard varS > 0 else { return (s, 1.0, 0) }
    let z: Double
    if s > 0      { z = (Double(s) - 1) / sqrt(varS) }
    else if s < 0 { z = (Double(s) + 1) / sqrt(varS) }
    else          { z = 0 }
    // Two-sided p from standard normal CDF approximation.
    let p = 2 * (1 - normalCDF(abs(z)))
    return (s, p, s > 0 ? 1 : (s < 0 ? -1 : 0))
}

/// Abramowitz & Stegun 26.2.17 — sufficient for our use, no fancy library needed.
private func normalCDF(_ x: Double) -> Double {
    let t = 1.0 / (1.0 + 0.2316419 * abs(x))
    let d = 0.3989422804014327 * exp(-x * x / 2)
    let p = d * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))))
    return x > 0 ? 1 - p : p
}

/// Local-level Kalman filter. Q (process noise) and R (observation noise) are
/// auto-tuned from the data: R = sample variance, Q = R / 10 (lightly smoothed).
private func kalmanLocalLevel(values xs: [Double]) -> [Double] {
    guard xs.count >= 2 else { return xs }
    let r = (stddev(xs) ?? 1) * (stddev(xs) ?? 1)
    let q = r / 10
    var mu = xs[0]
    var p = r
    var out: [Double] = []
    for y in xs {
        // Predict
        p += q
        // Update
        let k = p / (p + r)
        mu += k * (y - mu)
        p = (1 - k) * p
        out.append(mu)
    }
    return out
}

// MARK: - HK fetch helpers

/// Mean HR per hour over the last `hoursBack` hours.
private func hourlyMeanHR(store: HKHealthStore, hoursBack: Int) async -> [MetricPoint] {
    guard let t = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
    let end = Date()
    let start = end.addingTimeInterval(-Double(hoursBack) * 3600)
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let q = HKStatisticsCollectionQuery(quantityType: t, quantitySamplePredicate: predicate,
                                        options: .discreteAverage, anchorDate: start,
                                        intervalComponents: DateComponents(hour: 1))
    let unit = HKUnit.count().unitDivided(by: .minute())
    return await withCheckedContinuation { cont in
        q.initialResultsHandler = { _, results, _ in
            var pts: [MetricPoint] = []
            results?.enumerateStatistics(from: start, to: end) { stat, _ in
                if let q = stat.averageQuantity(), q.is(compatibleWith: unit) {
                    let v = q.doubleValue(for: unit)
                    if v.isFinite { pts.append(MetricPoint(date: stat.startDate, value: v)) }
                }
            }
            cont.resume(returning: pts)
        }
        store.execute(q)
    }
}

private func hourlyTotalSteps(store: HKHealthStore, hoursBack: Int) async -> [MetricPoint] {
    guard let t = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
    let end = Date()
    let start = end.addingTimeInterval(-Double(hoursBack) * 3600)
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let q = HKStatisticsCollectionQuery(quantityType: t, quantitySamplePredicate: predicate,
                                        options: .cumulativeSum, anchorDate: start,
                                        intervalComponents: DateComponents(hour: 1))
    let unit = HKUnit.count()
    return await withCheckedContinuation { cont in
        q.initialResultsHandler = { _, results, _ in
            var pts: [MetricPoint] = []
            results?.enumerateStatistics(from: start, to: end) { stat, _ in
                if let q = stat.sumQuantity(), q.is(compatibleWith: unit) {
                    pts.append(MetricPoint(date: stat.startDate, value: q.doubleValue(for: unit)))
                }
            }
            cont.resume(returning: pts)
        }
        store.execute(q)
    }
}

/// Per-night bedtime as minutes-past-midnight of the night's *start*. For
/// bedtimes after midnight, we wrap (so 01:30 → 1530 not 90) — this keeps
/// the series monotonically comparable for trend-tests where "later" means
/// numerically higher even when crossing midnight.
private func fetchNightlyBedtimes(store: HKHealthStore, days: Int) async -> [MetricPoint] {
    guard let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
    let cal = Calendar.current
    let end = cal.startOfDay(for: Date())
    let start = cal.date(byAdding: .day, value: -days, to: end)!
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let samples: [HKCategorySample] = await withCheckedContinuation { cont in
        let q = HKSampleQuery(sampleType: t, predicate: predicate,
                              limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
            cont.resume(returning: (s as? [HKCategorySample]) ?? [])
        }
        store.execute(q)
    }
    let asleep = samples.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
    // Group by night-of (attribute to wake-day).
    var byWakeDay: [Date: Date] = [:]  // wakeDay → earliest sleep start that night
    for s in asleep {
        let wakeDay = cal.startOfDay(for: s.endDate)
        if let existing = byWakeDay[wakeDay] {
            if s.startDate < existing { byWakeDay[wakeDay] = s.startDate }
        } else {
            byWakeDay[wakeDay] = s.startDate
        }
    }
    return byWakeDay.keys.sorted().map { wakeDay in
        let bedStart = byWakeDay[wakeDay]!
        let nightBefore = cal.date(byAdding: .day, value: -1, to: wakeDay)!
        // Minutes past noon-of-day-before. So 23:00 → 660, 02:00 → 840.
        // This keeps before/after midnight comparable and monotonic.
        let noonBefore = cal.date(byAdding: .hour, value: 12, to: nightBefore)!
        let minsPastNoon = bedStart.timeIntervalSince(noonBefore) / 60.0
        return MetricPoint(date: wakeDay, value: minsPastNoon)
    }
}
