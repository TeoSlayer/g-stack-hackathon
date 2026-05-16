import Foundation
import HealthKit

// MARK: - Tier 1: Autonomic metrics

extension Models {

    // Metric 23 — HIGH PRIORITY: most reliable early illness signal.
    // RR is extremely stable in health; any deviation flags infection or exhaustion.
    static func rrDeviation(store: HKHealthStore) async -> ModelReading {
        let pts = await dailyStats(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()),
                                   options: .discreteAverage, days: 30, store: store)
        let vals = pts.map(\.value)
        guard vals.count >= 4 else {
            return unknown(.rrDeviation, reason: "Need 4+ days of respiratory rate data.")
        }
        let acute   = ewmaLast(vals, lambda: 0.500)!   // span=3
        let chronic = ewmaLast(vals, lambda: 0.0645)!  // span=30
        let dev = acute - chronic
        let band: Band
        let action: String
        switch dev {
        case ..<0.5:  (band, action) = (.good, "Breathing rate stable — no illness signal.")
        case ..<1.5:  (band, action) = (.ok,   "Mild respiratory uptick. Watch over the next 24h.")
        case ..<2.5:  (band, action) = (.warn, "RR elevated above chronic baseline. Rest and monitor — early illness or exhaustion.")
        default:       (band, action) = (.bad,  "Significant respiratory rate spike. Likely illness or severe fatigue — reduce load.")
        }
        return ModelReading(id: .rrDeviation, title: ModelKind.rrDeviation.displayName,
                            valueText: String(format: "%+.2f brpm", dev),
                            band: band, action: action,
                            detail: String(format: "Acute %.1f vs chronic %.1f · \(ModelKind.rrDeviation.citation)", acute, chronic),
                            series: pts)
    }

    // Metric 33 — Single most interpretable nightly recovery signal.
    // Positive = sleep cleared stress. Negative = woke more stressed than you went to bed.
    static func vagalRebound(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let windowEnd   = cal.date(byAdding: .hour, value: 14, to: today)!

        let sleep = await categorySamples(.sleepAnalysis, start: windowStart, end: windowEnd, store: store)
        let asleep = sleep.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                                    $0.value != HKCategoryValueSleepAnalysis.awake.rawValue }
        guard let bedUtc  = sleep.filter({ $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }).map(\.startDate).min(),
              let wakeUtc = asleep.map(\.endDate).max() else {
            return unknown(.vagalRebound, reason: "No sleep window found for last night.")
        }
        let unit = HKUnit.secondUnit(with: .milli)
        let preSleep  = await quantitySamples(.heartRateVariabilitySDNN,
                                              start: bedUtc.addingTimeInterval(-3600), end: bedUtc,
                                              unit: unit, store: store).map(\.value)
        let postWake  = await quantitySamples(.heartRateVariabilitySDNN,
                                              start: wakeUtc, end: wakeUtc.addingTimeInterval(3600),
                                              unit: unit, store: store).map(\.value)
        guard !preSleep.isEmpty, !postWake.isEmpty else {
            return unknown(.vagalRebound, reason: "HRV samples not captured around sleep boundaries.")
        }
        let rebound = preSleep.reduce(0, +) / Double(preSleep.count)
        let post    = postWake.reduce(0, +) / Double(postWake.count)
        let delta   = post - rebound
        let band: Band
        let action: String
        switch delta {
        case ..<(-10): (band, action) = (.bad,  "Woke significantly more stressed than you fell asleep — severe unresolved load.")
        case ..<(-5):  (band, action) = (.warn, "Sleep didn't clear yesterday's stress. Prioritize recovery today.")
        case ..<3:     (band, action) = (.ok,   "Neutral overnight recovery.")
        default:        (band, action) = (.good, "Sleep restored your autonomic balance. Strong rebound.")
        }
        return ModelReading(id: .vagalRebound, title: ModelKind.vagalRebound.displayName,
                            valueText: String(format: "%+.0f ms", delta),
                            band: band, action: action,
                            detail: String(format: "Pre-sleep %.0f ms → post-wake %.0f ms · \(ModelKind.vagalRebound.citation)", rebound, post))
    }

    // Metric 5 — Leading indicator of accumulating fatigue or illness.
    // A rising slope appears days before subjective symptoms.
    static func rhrSlopeMetric(store: HKHealthStore,
                                cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        let series = await seriesOrFetch(.rhr, days: 7, cache: cache, store: store)
        let vals = series.history.suffix(7).map(\.value)
        guard vals.count >= 4, let slope = linregSlope(Array(vals)) else {
            return unknown(.rhrSlope, reason: "Need 4+ days of resting heart rate.")
        }
        let band: Band
        let action: String
        switch slope {
        case ..<(-0.3): (band, action) = (.good, "RHR trending down — recovering well.")
        case ..<0.3:    (band, action) = (.ok,   "RHR flat. No fatigue signal.")
        case ..<0.8:    (band, action) = (.warn, "RHR creeping up. Watch for further drift this week.")
        default:         (band, action) = (.bad,  "RHR rising consistently — likely accumulating fatigue or illness. Pull back load.")
        }
        return ModelReading(id: .rhrSlope, title: ModelKind.rhrSlope.displayName,
                            valueText: String(format: "%+.2f bpm/day", slope),
                            band: band, action: action,
                            detail: "7-day linear regression · \(ModelKind.rhrSlope.citation)",
                            series: Array(series.history.suffix(7)))
    }

    // Metric 8 — Orthostatic stress proxy. High surge = poor recovery, dehydration, or high cortisol.
    static func morningSurge(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let windowEnd   = cal.date(byAdding: .hour, value: 14, to: today)!

        let sleep = await categorySamples(.sleepAnalysis, start: windowStart, end: windowEnd, store: store)
        let asleep = sleep.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                                    $0.value != HKCategoryValueSleepAnalysis.awake.rawValue }
        guard let wakeUtc = asleep.map(\.endDate).max() else {
            return unknown(.morningSurge, reason: "No wake time found for last night.")
        }
        let hrUnit = HKUnit.count().unitDivided(by: .minute())
        let preWake  = await quantitySamples(.heartRate,
                                             start: wakeUtc.addingTimeInterval(-7200), end: wakeUtc,
                                             unit: hrUnit, store: store).map(\.value)
        let postWake = await quantitySamples(.heartRate,
                                             start: wakeUtc, end: wakeUtc.addingTimeInterval(600),
                                             unit: hrUnit, store: store).map(\.value)
        guard !preWake.isEmpty, !postWake.isEmpty else {
            return unknown(.morningSurge, reason: "Heart rate samples not available around wake time.")
        }
        let avgPre = preWake.reduce(0, +) / Double(preWake.count)
        let maxPost = postWake.max()!
        let surge = maxPost - avgPre
        let band: Band
        let action: String
        switch surge {
        case ..<20:  (band, action) = (.good, "Smooth HR transition on waking — well hydrated and recovered.")
        case ..<30:  (band, action) = (.ok,   "Moderate morning surge. Normal range.")
        case ..<40:  (band, action) = (.warn, "Elevated surge. Drink water before getting up tomorrow.")
        default:      (band, action) = (.bad,  "High orthostatic surge — dehydration, cortisol spike, or poor recovery. Hydrate now.")
        }
        return ModelReading(id: .morningSurge, title: ModelKind.morningSurge.displayName,
                            valueText: String(format: "%.0f bpm", surge),
                            band: band, action: action,
                            detail: String(format: "Max HR +10 min (%.0f) − avg 2h pre-wake (%.0f) · \(ModelKind.morningSurge.citation)", maxPost, avgPre))
    }

    // Metric 2 — Injury prevention. ACWR > 1.5 = danger zone; < 0.8 = detraining.
    static func acwrMetric(store: HKHealthStore) async -> ModelReading {
        let pts = await dailyStats(.activeEnergyBurned, unit: .kilocalorie(),
                                   options: .cumulativeSum, days: 28, store: store)
        let vals = pts.map(\.value)
        guard vals.count >= 7,
              let acute   = ewmaLast(Array(vals.suffix(7)),  lambda: 0.2857),
              let chronic = ewmaLast(vals, lambda: 0.0741),
              chronic > 0 else {
            return unknown(.acwr, reason: "Need 7+ days of active energy data.")
        }
        let ratio = acute / chronic
        let band: Band
        let action: String
        switch ratio {
        case ..<0.8:    (band, action) = (.warn, "Training load well below chronic baseline — detraining risk. Add a session.")
        case ..<1.3:    (band, action) = (.good, "Load well within safe zone.")
        case ..<1.5:    (band, action) = (.ok,   "Load slightly elevated. Monitor for fatigue.")
        default:         (band, action) = (.bad,  "Acute load spike — injury risk is elevated. Back off intensity this week.")
        }
        return ModelReading(id: .acwr, title: ModelKind.acwr.displayName,
                            valueText: String(format: "%.2f", ratio),
                            band: band, action: action,
                            detail: String(format: "Acute EWMA %.0f kcal / chronic %.0f kcal · \(ModelKind.acwr.citation)", acute, chronic),
                            series: pts)
    }

    // Metric 1 — ANS stability. High CV = nervous system swinging between stress and recovery.
    static func hrvCVMetric(store: HKHealthStore,
                             cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        let series = await seriesOrFetch(.hrv, days: 7, cache: cache, store: store)
        let vals = series.history.suffix(7).map(\.value)
        guard vals.count >= 4 else {
            return unknown(.hrvCV, reason: "Need 4+ days of HRV data.")
        }
        let m = vals.reduce(0, +) / Double(vals.count)
        guard m > 0, let sd = stddev(Array(vals)) else {
            return unknown(.hrvCV, reason: "Cannot compute stddev — not enough variance.")
        }
        let cv = sd / m
        let band: Band
        let action: String
        switch cv {
        case ..<0.15:  (band, action) = (.good, "HRV very consistent — ANS stable.")
        case ..<0.25:  (band, action) = (.ok,   "Normal HRV variation.")
        case ..<0.35:  (band, action) = (.warn, "High HRV swings — stress and recovery alternating sharply. Aim for consistency.")
        default:        (band, action) = (.bad,  "Erratic HRV — nervous system unstable. Reduce stressors, enforce sleep schedule.")
        }
        return ModelReading(id: .hrvCV, title: ModelKind.hrvCV.displayName,
                            valueText: String(format: "%.2f", cv),
                            band: band, action: action,
                            detail: String(format: "σ=%.1f ms, μ=%.1f ms · \(ModelKind.hrvCV.citation)", sd, m),
                            series: Array(series.history.suffix(7)))
    }
}

// MARK: - Tier 2: Sleep precision

extension Models {

    // Metric 10 — Penalises time-in-bed without restorative sleep.
    // Only deep (4) and REM (5) count; generic asleep (1) and core (3) are ignored.
    static func sleepEfficiencyMetric(store: HKHealthStore) async -> ModelReading {
        let (deepRemSec, inBedSec) = await lastNightDeepRemAndInBed(store: store)
        guard inBedSec > 0 else {
            return unknown(.sleepEfficiency, reason: "No in-bed data found for last night.")
        }
        guard deepRemSec > 0 else {
            return unknown(.sleepEfficiency, reason: "No deep/REM data — may be pre-Series 9 watch.")
        }
        let eff = deepRemSec / inBedSec
        let pct = Int((eff * 100).rounded())
        let band: Band
        let action: String
        switch eff {
        case ..<0.30:  (band, action) = (.bad,  "Very poor sleep quality — too little deep/REM. Avoid alcohol and late screens.")
        case ..<0.40:  (band, action) = (.warn, "Below target. Cut screen time 90 min before bed.")
        case ..<0.55:  (band, action) = (.ok,   "Acceptable architecture. Room to improve.")
        default:        (band, action) = (.good, "Good deep+REM proportion.")
        }
        return ModelReading(id: .sleepEfficiency, title: ModelKind.sleepEfficiency.displayName,
                            valueText: "\(pct)%",
                            band: band, action: action,
                            detail: String(format: "Deep+REM %.0f min / in-bed %.0f min · \(ModelKind.sleepEfficiency.citation)",
                                           deepRemSec / 60, inBedSec / 60))
    }

    // Metric 13 — Intra-sleep fragmentation. Counts only awake segments strictly between first and last asleep.
    static func wasoMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let end   = cal.date(byAdding: .hour, value: 14, to: today)!

        let samples = await categorySamples(.sleepAnalysis, start: start, end: end, store: store)
        let asleepVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
        let asleep = samples.filter { asleepVals.contains($0.value) }
        let awake  = samples.filter { $0.value == HKCategoryValueSleepAnalysis.awake.rawValue }
        guard let firstAsleep = asleep.map(\.startDate).min(),
              let lastAsleepEnd = asleep.map(\.endDate).max() else {
            return unknown(.waso, reason: "No asleep samples found for last night.")
        }
        let wasoSec = awake
            .filter { $0.startDate >= firstAsleep && $0.endDate <= lastAsleepEnd }
            .map { $0.endDate.timeIntervalSince($0.startDate) }
            .reduce(0, +)
        let wasoMin = Int(wasoSec / 60)
        let band: Band
        let action: String
        switch wasoMin {
        case 0...10:   (band, action) = (.good, "Minimal mid-sleep waking.")
        case 11...30:  (band, action) = (.ok,   "Some fragmentation — normal for most adults.")
        case 31...60:  (band, action) = (.warn, "High WASO. Check for noise, temperature, or caffeine timing.")
        default:        (band, action) = (.bad,  "Severely fragmented sleep. Consider sleep hygiene audit.")
        }
        return ModelReading(id: .waso, title: ModelKind.waso.displayName,
                            valueText: "\(wasoMin) min",
                            band: band, action: action,
                            detail: "Awake between first and last asleep · \(ModelKind.waso.citation)")
    }

    // Metric 12 — Sleep onset latency z-score vs personal 30-day baseline.
    static func solSpikeMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var sols: [Double] = []
        for i in 0..<30 {
            let dayStart = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -(i + 1), to: today)!)!
            let dayEnd   = cal.date(byAdding: .hour, value: 14, to: cal.date(byAdding: .day, value: -i, to: today)!)!
            let samples  = await categorySamples(.sleepAnalysis, start: dayStart, end: dayEnd, store: store)
            let asleepVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
            guard let inBedStart  = samples.filter({ $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }).map(\.startDate).min(),
                  let firstAsleep = samples.filter({ asleepVals.contains($0.value) }).map(\.startDate).min() else { continue }
            sols.append(firstAsleep.timeIntervalSince(inBedStart) / 60.0)
        }
        guard sols.count >= 7, let todaySOL = sols.first else {
            return unknown(.solSpike, reason: "Need 7+ nights with both in-bed and asleep timestamps.")
        }
        let baseline = sols.dropFirst()
        let mu = baseline.reduce(0, +) / Double(baseline.count)
        guard let sd = stddev(Array(baseline)), sd > 0 else {
            return unknown(.solSpike, reason: "Not enough variance in sleep onset data.")
        }
        let z = (todaySOL - mu) / sd
        let band: Band
        let action: String
        switch z {
        case ..<1.0:   (band, action) = (.good, "Falling asleep at your normal pace.")
        case ..<2.0:   (band, action) = (.ok,   "Slightly slower onset than usual — likely mild stress or caffeine.")
        default:        (band, action) = (.bad,  "Sleep onset significantly delayed vs your baseline. Check screen use and caffeine cutoff time.")
        }
        return ModelReading(id: .solSpike, title: ModelKind.solSpike.displayName,
                            valueText: String(format: "%.0f min (z=%+.1f)", todaySOL, z),
                            band: band, action: action,
                            detail: String(format: "Baseline %.0f ± %.0f min · \(ModelKind.solSpike.citation)", mu, sd))
    }

    // Metric 15 — Metabolic disruption from weekend vs weekday sleep drift.
    static func socialJetlagMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var weekdayMids: [Double] = []
        var weekendMids: [Double] = []
        for i in 0..<28 {
            let dayStart = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -(i + 1), to: today)!)!
            let dayEnd   = cal.date(byAdding: .hour, value: 14, to: cal.date(byAdding: .day, value: -i, to: today)!)!
            let samples  = await categorySamples(.sleepAnalysis, start: dayStart, end: dayEnd, store: store)
            let asleepVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
            guard let inBedStart  = samples.filter({ $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }).map(\.startDate).min(),
                  let lastSleepEnd = samples.filter({ asleepVals.contains($0.value) }).map(\.endDate).max() else { continue }
            let midpoint = inBedStart.timeIntervalSince1970 + lastSleepEnd.timeIntervalSince(inBedStart) / 2
            let weekday = cal.component(.weekday, from: inBedStart)
            if weekday == 7 || weekday == 1 { weekendMids.append(midpoint) }
            else { weekdayMids.append(midpoint) }
        }
        guard weekdayMids.count >= 2, weekendMids.count >= 2 else {
            return unknown(.socialJetlag, reason: "Need ≥2 weekend and ≥2 weekday nights in the last 28 days.")
        }
        let wdAvg = weekdayMids.reduce(0, +) / Double(weekdayMids.count)
        let weAvg = weekendMids.reduce(0, +) / Double(weekendMids.count)
        let sji = abs(weAvg - wdAvg) / 3600.0
        let band: Band
        let action: String
        switch sji {
        case ..<0.5:   (band, action) = (.good, "Consistent sleep schedule — no social jetlag.")
        case ..<1.0:   (band, action) = (.ok,   "Mild drift between weekday and weekend. Acceptable.")
        case ..<2.0:   (band, action) = (.warn, "Social jetlag detected. Try keeping weekend sleep within 1h of weekdays.")
        default:        (band, action) = (.bad,  "Severe social jetlag — metabolic disruption risk. Anchor your wake time on weekends.")
        }
        return ModelReading(id: .socialJetlag, title: ModelKind.socialJetlag.displayName,
                            valueText: String(format: "%.1f h", sji),
                            band: band, action: action,
                            detail: "Weekend vs weekday sleep midpoint delta · \(ModelKind.socialJetlag.citation)")
    }
}

// MARK: - Tier 3: Metabolic / behavioral

extension Models {

    // Metric 24 — Sleep apnea proxy. Only overnight SpO2 desaturations count.
    static func spO2DensityMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let windowStart = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let windowEnd   = cal.date(byAdding: .hour, value: 14, to: today)!

        let sleep  = await categorySamples(.sleepAnalysis, start: windowStart, end: windowEnd, store: store)
        let asleepVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                    HKCategoryValueSleepAnalysis.inBed.rawValue]
        let sleepSamples = sleep.filter { asleepVals.contains($0.value) }
        guard let sleepStart = sleepSamples.map(\.startDate).min(),
              let sleepEnd   = sleepSamples.map(\.endDate).max() else {
            return unknown(.spO2Density, reason: "No sleep window found for last night.")
        }
        let sleepHours = sleepEnd.timeIntervalSince(sleepStart) / 3600.0
        guard sleepHours > 1 else {
            return unknown(.spO2Density, reason: "Sleep window too short to analyse.")
        }
        let spo2 = await quantitySamples(.oxygenSaturation,
                                         start: sleepStart, end: sleepEnd,
                                         unit: .percent(), store: store)
        let desats = spo2.filter { $0.value < 94.0 }.count
        let density = Double(desats) / sleepHours
        let band: Band
        let action: String
        switch density {
        case ..<2:    (band, action) = (.good, "Normal overnight oxygen saturation.")
        case ..<5:    (band, action) = (.ok,   "Mild desaturation events. Monitor trend.")
        case ..<15:   (band, action) = (.warn, "Elevated desaturation density — possible mild sleep apnea. Mention to a doctor.")
        default:       (band, action) = (.bad,  "High overnight desaturation rate — potential sleep apnea. Seek medical evaluation.")
        }
        return ModelReading(id: .spO2Density, title: ModelKind.spO2Density.displayName,
                            valueText: String(format: "%.1f /hr", density),
                            band: band, action: action,
                            detail: String(format: "%d events < 94%% over %.1f h · \(ModelKind.spO2Density.citation)", desats, sleepHours))
    }

    // Metric 17 — Cumulative harmful noise. High load days correlate with elevated cortisol.
    static func acousticLoadMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        guard let noiseType = HKObjectType.quantityType(forIdentifier: .environmentalAudioExposure) else {
            return unknown(.acousticLoad, reason: "Environmental audio not available on this device.")
        }
        let predicate = HKQuery.predicateForSamples(withStart: today, end: tomorrow, options: .strictStartDate)
        let unit = HKUnit(from: "dBASPL")
        let samples: [(start: Date, end: Date, value: Double)] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: noiseType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                let result = (s as? [HKQuantitySample] ?? []).compactMap { s -> (Date, Date, Double)? in
                    guard s.quantity.is(compatibleWith: unit) else { return nil }
                    let v = s.quantity.doubleValue(for: unit)
                    return v.isFinite ? (s.startDate, s.endDate, v) : nil
                }
                cont.resume(returning: result)
            }
            store.execute(q)
        }
        let threshold = 75.0
        let load = samples
            .filter { $0.value > threshold }
            .map { ($0.value - threshold) * ($0.end.timeIntervalSince($0.start) / 3600.0) }
            .reduce(0, +)
        let band: Band
        let action: String
        switch load {
        case ..<5:    (band, action) = (.good, "Low noise exposure today.")
        case ..<20:   (band, action) = (.ok,   "Moderate acoustic load. Consider quiet time this evening.")
        case ..<50:   (band, action) = (.warn, "High noise exposure. Use hearing protection and take quiet breaks.")
        default:       (band, action) = (.bad,  "Very high acoustic load — elevated cortisol risk. Get to a quiet environment.")
        }
        return ModelReading(id: .acousticLoad, title: ModelKind.acousticLoad.displayName,
                            valueText: String(format: "%.1f dB·h", load),
                            band: band, action: action,
                            detail: "Σ(dB − 75) × hours above 75 dBASPL today · \(ModelKind.acousticLoad.citation)")
    }

    // Metric 21 — Cumulative daylight deficit over rolling 3 days. Suppresses melatonin.
    static func lightDeficitMetric(store: HKHealthStore) async -> ModelReading {
        let pts = await dailyStats(.timeInDaylight, unit: .minute(),
                                   options: .cumulativeSum, days: 3, store: store)
        guard !pts.isEmpty else {
            return unknown(.lightDeficit, reason: "No daylight data — requires iOS 17 and Apple Watch.")
        }
        let target = 120.0
        let debt = pts.map { max(0, target - $0.value) }.reduce(0, +)
        let band: Band
        let action: String
        switch debt {
        case ..<30:    (band, action) = (.good, "Getting enough daylight — melatonin rhythm intact.")
        case ..<90:    (band, action) = (.ok,   "Mild light deficit. Try a 20-min outdoor walk today.")
        case ..<150:   (band, action) = (.warn, "Significant daylight shortfall. Outdoor light before noon helps reset circadian timing.")
        default:        (band, action) = (.bad,  "Severe light deficit over 3 days — circadian suppression likely. Prioritise morning sunlight.")
        }
        return ModelReading(id: .lightDeficit, title: ModelKind.lightDeficit.displayName,
                            valueText: String(format: "%.0f min debt", debt),
                            band: band, action: action,
                            detail: String(format: "Target 120 min/day · last %d days with data · \(ModelKind.lightDeficit.citation)", pts.count),
                            series: pts)
    }

    // Metric 22 — Movement distribution through the day. Low = prolonged sitting.
    static func sedentaryFragMetric(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        let standSamples = await categorySamples(.appleStandHour, start: today, end: tomorrow, store: store)
        let stood = standSamples.filter { $0.value == HKCategoryValueAppleStandHour.stood.rawValue }.count

        // Approximate awake hours = 24 - sleep hours for last night
        let sleepWindow = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let sleepSamples = await categorySamples(.sleepAnalysis, start: sleepWindow, end: tomorrow, store: store)
        let asleepVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
        let sleepSec = TimeSeries.mergedDuration(sleepSamples.filter { asleepVals.contains($0.value) })
        let awakeHours = max(1, 24.0 - sleepSec / 3600.0)
        let sfr = Double(stood) / awakeHours
        let band: Band
        let action: String
        if sfr >= 1.0 {
            (band, action) = (.good, "Moving every hour — excellent movement distribution.")
        } else if sfr >= 0.75 {
            (band, action) = (.ok,   "Mostly active. Aim to stand every hour.")
        } else if sfr >= 0.5 {
            (band, action) = (.warn, "Prolonged sitting detected. Set an hourly stand reminder.")
        } else {
            (band, action) = (.bad,  "Mostly sedentary. Chronic sitting raises cardiovascular risk regardless of workouts.")
        }
        return ModelReading(id: .sedentaryFrag, title: ModelKind.sedentaryFrag.displayName,
                            valueText: String(format: "%.2f /hr", sfr),
                            band: band, action: action,
                            detail: String(format: "%d stand hours / %.0f awake hours · \(ModelKind.sedentaryFrag.citation)", stood, awakeHours))
    }

    // Metric 25 — High weekly mass swings = water/glycogen flux, not fat. Prevents misinterpretation.
    static func bodyMassVolatilityMetric(store: HKHealthStore) async -> ModelReading {
        let pts = await dailyStats(.bodyMass, unit: .gramUnit(with: .kilo),
                                   options: .discreteAverage, days: 7, store: store)
        guard pts.count >= 3 else {
            return unknown(.bodyMassVolatility, reason: "Need ≥3 weigh-ins in the last 7 days.")
        }
        guard let vol = stddev(pts.map(\.value)) else {
            return unknown(.bodyMassVolatility, reason: "Cannot compute volatility.")
        }
        let band: Band
        let action: String
        switch vol {
        case ..<0.5:   (band, action) = (.good, "Stable body mass — changes reflect true composition shift.")
        case ..<1.0:   (band, action) = (.ok,   "Normal day-to-day fluctuation from food and hydration.")
        case ..<1.5:   (band, action) = (.warn, "High mass swings — likely hydration or glycogen variance, not fat change.")
        default:        (band, action) = (.bad,  "Very high mass volatility — avoid reading daily weight as a trend this week.")
        }
        return ModelReading(id: .bodyMassVolatility, title: ModelKind.bodyMassVolatility.displayName,
                            valueText: String(format: "±%.1f kg", vol),
                            band: band, action: action,
                            detail: "7-day stddev · \(ModelKind.bodyMassVolatility.citation)",
                            series: pts)
    }

    // Metric 27 — Detects detraining before performance decline is felt.
    static func vo2TrendMetric(store: HKHealthStore) async -> ModelReading {
        guard let vo2Type = HKObjectType.quantityType(forIdentifier: .vo2Max) else {
            return unknown(.vo2Trend, reason: "VO2 Max not available.")
        }
        let unit = HKUnit(from: "ml/kg*min")
        let now = Date()
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86400)

        let recent: [HKQuantitySample] = await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: thirtyDaysAgo, end: now, options: .strictStartDate)
            let q = HKSampleQuery(sampleType: vo2Type, predicate: pred,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, s, _ in
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
        guard let first = recent.first, let last = recent.last, first.startDate < last.startDate else {
            return unknown(.vo2Trend, reason: "Need at least 2 VO2 Max readings in the last 30 days.")
        }
        let days = last.startDate.timeIntervalSince(first.startDate) / 86400.0
        guard days >= 1 else {
            return unknown(.vo2Trend, reason: "Readings too close together.")
        }
        let v0 = first.quantity.doubleValue(for: unit)
        let v1 = last.quantity.doubleValue(for: unit)
        let deriv = (v1 - v0) / days
        let band: Band
        let action: String
        if deriv >= 0.05 {
            (band, action) = (.good, "VO2 Max improving — fitness adapting.")
        } else if deriv >= -0.05 {
            (band, action) = (.ok,   "VO2 Max stable. Maintain consistency.")
        } else {
            (band, action) = (.warn, "VO2 Max declining — detraining signal. Add a cardio session this week.")
        }
        return ModelReading(id: .vo2Trend, title: ModelKind.vo2Trend.displayName,
                            valueText: String(format: "%+.3f ml/kg/min/day", deriv),
                            band: band, action: action,
                            detail: String(format: "%.1f → %.1f ml/kg·min over %.0f days · \(ModelKind.vo2Trend.citation)", v0, v1, days))
    }

    // Metric 32 — Rate of change of combined debt signals. Positive slope = approaching crash.
    // Uses sleep deficit + WASO proxy over 7 nights (no persistence required).
    static func burnoutVelocityMetric(store: HKHealthStore,
                                      cache: [MetricKind: MetricSeries] = [:]) async -> ModelReading {
        let sleepSeries = await seriesOrFetch(.sleep, days: 7, cache: cache, store: store)
        let vals = sleepSeries.history.suffix(7).map(\.value)
        guard vals.count >= 4 else {
            return unknown(.burnoutVelocity, reason: "Need 4+ nights of sleep data.")
        }
        // burnout_signal[day] ≈ sleep_deficit_hours (positive = bad)
        let target = 8.0
        let signal = vals.map { max(0, target - $0) }
        guard let slope = linregSlope(signal) else {
            return unknown(.burnoutVelocity, reason: "Cannot compute slope.")
        }
        let band: Band
        let action: String
        switch slope {
        case ..<(-0.1): (band, action) = (.good, "Sleep debt decreasing — recovery trajectory.")
        case ..<0.1:    (band, action) = (.ok,   "Stable load. No burnout acceleration.")
        case ..<0.3:    (band, action) = (.warn, "Sleep deficit growing. Build in a recovery night before this compounds.")
        default:         (band, action) = (.bad,  "Rapidly accumulating debt — burnout trajectory. Protect sleep aggressively this week.")
        }
        return ModelReading(id: .burnoutVelocity, title: ModelKind.burnoutVelocity.displayName,
                            valueText: String(format: "%+.2f h/day", slope),
                            band: band, action: action,
                            detail: "Regression slope on 7-night sleep deficit · \(ModelKind.burnoutVelocity.citation)",
                            series: sleepSeries.history.suffix(7).map { MetricPoint(date: $0.date, value: max(0, target - $0.value)) })
    }
}

// MARK: - Shared HK fetch helpers

extension Models {

    static func dailyStats(_ identifier: HKQuantityTypeIdentifier,
                            unit: HKUnit,
                            options: HKStatisticsOptions,
                            days: Int,
                            store: HKHealthStore) async -> [MetricPoint] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -days, to: today)!
        let end   = cal.date(byAdding: .day, value: 1, to: today)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let q = HKStatisticsCollectionQuery(quantityType: type,
                                            quantitySamplePredicate: predicate,
                                            options: options,
                                            anchorDate: start,
                                            intervalComponents: DateComponents(day: 1))
        return await withCheckedContinuation { cont in
            q.initialResultsHandler = { _, results, _ in
                var pts: [MetricPoint] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let qty = options.contains(.cumulativeSum) ? stat.sumQuantity() : stat.averageQuantity()
                    guard let q = qty, q.is(compatibleWith: unit) else { return }
                    let v = q.doubleValue(for: unit)
                    guard v.isFinite, v > 0 else { return }
                    pts.append(MetricPoint(date: stat.startDate, value: v))
                }
                cont.resume(returning: pts)
            }
            store.execute(q)
        }
    }

    static func categorySamples(_ identifier: HKCategoryTypeIdentifier,
                                  start: Date, end: Date,
                                  store: HKHealthStore) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
    }

    static func quantitySamples(_ identifier: HKQuantityTypeIdentifier,
                                  start: Date, end: Date,
                                  unit: HKUnit,
                                  store: HKHealthStore) async -> [(date: Date, value: Double)] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                let result = (s as? [HKQuantitySample] ?? []).compactMap { s -> (Date, Double)? in
                    guard s.quantity.is(compatibleWith: unit) else { return nil }
                    let v = s.quantity.doubleValue(for: unit)
                    return v.isFinite ? (s.startDate, v) : nil
                }
                cont.resume(returning: result)
            }
            store.execute(q)
        }
    }

    // Returns (deep+REM seconds, in-bed seconds) for the most recent sleep session.
    private static func lastNightDeepRemAndInBed(store: HKHealthStore) async -> (Double, Double) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: -1, to: today)!)!
        let end   = cal.date(byAdding: .hour, value: 14, to: today)!
        let samples = await categorySamples(.sleepAnalysis, start: start, end: end, store: store)
        let deepRemVals: Set<Int> = [HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                     HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let deepRemSec = samples
            .filter { deepRemVals.contains($0.value) }
            .map { $0.endDate.timeIntervalSince($0.startDate) }
            .reduce(0, +)
        let inBedSec = samples
            .filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
            .map { $0.endDate.timeIntervalSince($0.startDate) }
            .reduce(0, +)
        return (deepRemSec, inBedSec)
    }

    private static func unknown(_ kind: ModelKind, reason: String) -> ModelReading {
        ModelReading(id: kind, title: kind.displayName, valueText: "—",
                     band: .unknown, action: reason, detail: kind.citation)
    }
}

// MARK: - Math helpers

extension Models {

    // Exponential moving average — returns the value at the last index.
    static func ewmaLast(_ values: [Double], lambda: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        var acc = values[0]
        for v in values.dropFirst() { acc = lambda * v + (1 - lambda) * acc }
        return acc
    }

    // OLS slope of y over equally-spaced x = [0, 1, …, n-1].
    static func linregSlope(_ ys: [Double]) -> Double? {
        let n = Double(ys.count)
        guard n >= 2 else { return nil }
        let xMean = (n - 1) / 2
        let yMean = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, y) in ys.enumerated() {
            let x = Double(i) - xMean
            num += x * (y - yMean)
            den += x * x
        }
        return den > 0 ? num / den : nil
    }
}

// MARK: - Metrics 3, 4, 29

extension Models {

    // Metric 3 — Same intensity every day plateaus fitness and raises overuse risk.
    static func trainingMonotony(store: HKHealthStore) async -> ModelReading {
        let pts = await dailyStats(.activeEnergyBurned, unit: .kilocalorie(),
                                   options: .cumulativeSum, days: 7, store: store)
        let vals = pts.map(\.value)
        guard vals.count >= 4, let sd = stddev(vals), sd > 0 else {
            return unknown(.trainingMonotony, reason: "Need 4+ days of active energy data with variance.")
        }
        let m = vals.reduce(0, +) / Double(vals.count)
        let monotony = m / sd
        let band: Band
        let action: String
        switch monotony {
        case ..<1.0:   (band, action) = (.good, "Good training variety this week.")
        case ..<1.5:   (band, action) = (.ok,   "Moderate monotony — acceptable.")
        case ..<2.0:   (band, action) = (.warn, "Same effort every day. Add a hard/easy day pattern.")
        default:        (band, action) = (.bad,  "High monotony — plateau or overuse risk. Vary intensity: one hard, one easy, one rest.")
        }
        return ModelReading(id: .trainingMonotony, title: ModelKind.trainingMonotony.displayName,
                            valueText: String(format: "%.2f", monotony),
                            band: band, action: action,
                            detail: String(format: "μ=%.0f kcal / σ=%.0f kcal · 7d · \(ModelKind.trainingMonotony.citation)", m, sd),
                            series: pts)
    }

    // Metric 4 — Flat nocturnal dip = alcohol, late eating, or acute illness.
    // Normal range 10–20%. Dip < 5% is a red flag.
    static func rhrDipAmplitude(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Daytime window: 08:00–22:00 local yesterday
        let dayStart = cal.date(byAdding: .hour, value: 8,  to: yesterday)!
        let dayEnd   = cal.date(byAdding: .hour, value: 22, to: yesterday)!

        // Sleep window for last night
        let sleepWindowStart = cal.date(byAdding: .hour, value: 20, to: yesterday)! // 8pm yesterday
        let sleepWindowEnd   = cal.date(byAdding: .hour, value: 10, to: today)!     // 10am today

        let hrUnit = HKUnit.count().unitDivided(by: .minute())

        async let daytimeHR  = quantitySamples(.heartRate, start: dayStart,         end: dayEnd,         unit: hrUnit, store: store)
        async let nocturnalHR = quantitySamples(.heartRate, start: sleepWindowStart, end: sleepWindowEnd, unit: hrUnit, store: store)
        let sleep = await categorySamples(.sleepAnalysis, start: sleepWindowStart, end: sleepWindowEnd, store: store)

        let (dtSamples, noSamples) = await (daytimeHR, nocturnalHR)
        guard !dtSamples.isEmpty else {
            return unknown(.rhrDip, reason: "No daytime heart rate data for yesterday.")
        }
        let dtAvg = dtSamples.map(\.value).reduce(0, +) / Double(dtSamples.count)

        // Narrow nocturnal HR to the inBed window if sleep data available, else use full night window.
        let inBedSamples = sleep.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
        let noctStart = inBedSamples.map(\.startDate).min() ?? sleepWindowStart
        let noctEnd   = sleep.filter { $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
                             .map(\.endDate).max() ?? sleepWindowEnd
        let noctVals = noSamples.filter { $0.date >= noctStart && $0.date <= noctEnd }.map(\.value)
        guard !noctVals.isEmpty else {
            return unknown(.rhrDip, reason: "No heart rate data captured during sleep window.")
        }
        let noctMin = noctVals.min()!
        let dip = (dtAvg - noctMin) / dtAvg

        let band: Band
        let action: String
        switch dip {
        case ..<0.05:  (band, action) = (.bad,  "Almost no nocturnal HR dip — likely alcohol, late meal, illness, or high stress.")
        case ..<0.10:  (band, action) = (.warn, "Below-normal dip. Check for late eating or alcohol the night before.")
        case ..<0.20:  (band, action) = (.good, "Normal nocturnal dip — autonomic system recovering well overnight.")
        default:        (band, action) = (.ok,   "Deep dip — good recovery, possibly athletic adaptation.")
        }
        return ModelReading(id: .rhrDip, title: ModelKind.rhrDip.displayName,
                            valueText: String(format: "%.0f%%", dip * 100),
                            band: band, action: action,
                            detail: String(format: "Daytime avg %.0f bpm → nocturnal min %.0f bpm · \(ModelKind.rhrDip.citation)", dtAvg, noctMin))
    }

    // Metric 29 — Lifestyle activity outside workouts. Detects training-induced laziness.
    static func neatProxy(store: HKHealthStore) async -> ModelReading {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!

        // Fetch today's workouts
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: today, end: tomorrow, options: .strictStartDate)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }

        // Total steps and active energy for today
        async let totalStepsPts   = dailyStats(.stepCount,          unit: .count(),      options: .cumulativeSum, days: 1, store: store)
        async let totalEnergyPts  = dailyStats(.activeEnergyBurned, unit: .kilocalorie(), options: .cumulativeSum, days: 1, store: store)
        let (stepsPts, energyPts) = await (totalStepsPts, totalEnergyPts)
        let totalSteps  = stepsPts.first?.value  ?? 0
        let totalEnergy = energyPts.first?.value ?? 0

        // Steps and energy within each workout window
        var workoutSteps  = 0.0
        var workoutEnergy = 0.0
        let stepUnit   = HKUnit.count()
        let energyUnit = HKUnit.kilocalorie()
        for w in workouts {
            let wSteps = await sumQuantity(.stepCount,          start: w.startDate, end: w.endDate, unit: stepUnit,   store: store)
            let wEnergy = await sumQuantity(.activeEnergyBurned, start: w.startDate, end: w.endDate, unit: energyUnit, store: store)
            workoutSteps  += wSteps
            workoutEnergy += wEnergy
        }

        let neatSteps  = max(0, totalSteps  - workoutSteps)
        let neatEnergy = max(0, totalEnergy - workoutEnergy)

        let band: Band
        let action: String
        switch Int(neatSteps) {
        case 7000...:  (band, action) = (.good, "High lifestyle activity — great NEAT.")
        case 4000...:  (band, action) = (.ok,   "Decent movement outside workouts.")
        case 2000...:  (band, action) = (.warn, "Low non-exercise activity. Walk more between tasks.")
        default:        (band, action) = (.bad,  "Very sedentary outside workouts. Training doesn't offset hours of sitting.")
        }
        return ModelReading(id: .neat, title: ModelKind.neat.displayName,
                            valueText: String(format: "%.0f steps / %.0f kcal", neatSteps, neatEnergy),
                            band: band, action: action,
                            detail: String(format: "Total %.0f steps − %.0f workout steps · \(ModelKind.neat.citation)", totalSteps, workoutSteps))
    }

    // Cumulative sum of a quantity type within a time window (used for per-workout NEAT subtraction).
    private static func sumQuantity(_ identifier: HKQuantityTypeIdentifier,
                                    start: Date, end: Date,
                                    unit: HKUnit,
                                    store: HKHealthStore) async -> Double {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, _ in
                guard let qty = stats?.sumQuantity(), qty.is(compatibleWith: unit) else {
                    cont.resume(returning: 0); return
                }
                let v = qty.doubleValue(for: unit)
                cont.resume(returning: v.isFinite ? v : 0)
            }
            store.execute(q)
        }
    }
}

// MARK: - TimeSeries internal helper exposed for sedentaryFrag

extension TimeSeries {
    static func mergedDuration(_ samples: [HKCategorySample]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let intervals = samples.map { (start: $0.startDate, end: $0.endDate) }.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = [intervals[0]]
        for cur in intervals.dropFirst() {
            var last = merged.removeLast()
            if cur.start <= last.end { last.end = max(last.end, cur.end); merged.append(last) }
            else { merged.append(last); merged.append(cur) }
        }
        return merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}
