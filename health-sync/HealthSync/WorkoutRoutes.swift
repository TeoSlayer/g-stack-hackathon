import Foundation
import HealthKit
import CoreLocation

/// One GPS point from a workout, paired with the nearest contemporaneous HR
/// sample. Built once per Map view load, cached in memory for the session.
struct LocatedSample {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let workoutType: UInt
    /// HR is recorded ~every 5 s during workouts, so each GPS point gets its
    /// own value via nearest-neighbour match.
    let heartRate: Double?
    /// Speed in m/s as reported by CoreLocation for this fix.
    let speedMPS: Double?
    /// Overnight HRV (mean SDNN, ms) attributed to the day this sample falls in.
    /// All samples from the same day share this value — HRV doesn't change second-to-second.
    let dailyHRV: Double?
    /// Apple's daily resting heart-rate value for the day this sample falls in.
    let dailyRHR: Double?
}

enum WorkoutRoutes {

    /// Pull every workout route from the last `daysBack` days and pair each GPS
    /// point with the nearest heart-rate sample inside that workout's window.
    /// All-in-memory; for a typical user this is in the low tens of thousands
    /// of points.
    static func fetchSamples(daysBack: Int, store: HKHealthStore) async -> [LocatedSample] {
        let end = Date()
        let start = end.addingTimeInterval(-Double(daysBack) * 86400)
        async let workoutsAsync = fetchWorkouts(start: start, end: end, store: store)
        // Pull daily HRV/RHR for the whole window in one HK statistics query each.
        async let dailyHRVAsync = dailyAverages(.heartRateVariabilitySDNN,
                                                unit: .secondUnit(with: .milli),
                                                start: start, end: end, store: store)
        async let dailyRHRAsync = dailyAverages(.restingHeartRate,
                                                unit: .count().unitDivided(by: .minute()),
                                                start: start, end: end, store: store)
        let (workouts, dailyHRV, dailyRHR) = await (workoutsAsync, dailyHRVAsync, dailyRHRAsync)

        let cal = Calendar.current
        var out: [LocatedSample] = []
        for w in workouts {
            let route = await firstRoute(for: w, store: store)
            guard let route else { continue }
            async let locs = locations(of: route, store: store)
            async let hrs  = heartRateSamples(start: w.startDate, end: w.endDate, store: store)
            let (points, hrSamples) = await (locs, hrs)
            let sortedHR = hrSamples.sorted { $0.startDate < $1.startDate }
            for p in points {
                let day = cal.startOfDay(for: p.timestamp)
                out.append(LocatedSample(
                    coordinate: p.coordinate,
                    timestamp: p.timestamp,
                    workoutType: w.workoutActivityType.rawValue,
                    heartRate: nearestHR(to: p.timestamp, samples: sortedHR),
                    speedMPS: p.speed >= 0 ? p.speed : nil,
                    dailyHRV: dailyHRV[day],
                    dailyRHR: dailyRHR[day]
                ))
            }
        }
        return out
    }

    /// Daily-aggregated mean for a quantity type, keyed by start-of-day.
    private static func dailyAverages(_ identifier: HKQuantityTypeIdentifier,
                                       unit: HKUnit, start: Date, end: Date,
                                       store: HKHealthStore) async -> [Date: Double] {
        guard let t = HKObjectType.quantityType(forIdentifier: identifier),
              end > start else { return [:] }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let q = HKStatisticsCollectionQuery(quantityType: t,
                                            quantitySamplePredicate: predicate,
                                            options: .discreteAverage,
                                            anchorDate: anchor,
                                            intervalComponents: DateComponents(day: 1))
        return await withCheckedContinuation { cont in
            q.initialResultsHandler = { _, results, _ in
                var map: [Date: Double] = [:]
                results?.enumerateStatistics(from: anchor, to: end) { stat, _ in
                    if let avg = stat.averageQuantity(), avg.is(compatibleWith: unit) {
                        let v = avg.doubleValue(for: unit)
                        if v.isFinite { map[stat.startDate] = v }
                    }
                }
                cont.resume(returning: map)
            }
            store.execute(q)
        }
    }

    // MARK: - HK queries

    private static func fetchWorkouts(start: Date, end: Date,
                                      store: HKHealthStore) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    private static func firstRoute(for workout: HKWorkout, store: HKHealthStore) async -> HKWorkoutRoute? {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let routeType = HKSeriesType.workoutRoute()
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: routeType, predicate: predicate,
                                  limit: 1, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: samples?.first as? HKWorkoutRoute)
            }
            store.execute(q)
        }
    }

    private static func locations(of route: HKWorkoutRoute, store: HKHealthStore) async -> [CLLocation] {
        await withCheckedContinuation { cont in
            var collected: [CLLocation] = []
            let q = HKWorkoutRouteQuery(route: route) { _, locs, done, err in
                if let locs { collected.append(contentsOf: locs) }
                if done || err != nil {
                    cont.resume(returning: collected)
                }
            }
            store.execute(q)
        }
    }

    private static func heartRateSamples(start: Date, end: Date,
                                         store: HKHealthStore) async -> [HKQuantitySample] {
        guard end > start, let t = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: t, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Binary search by start-date for the HR sample closest in time to `t`.
    private static func nearestHR(to t: Date, samples: [HKQuantitySample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].startDate < t { lo = mid + 1 } else { hi = mid }
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        // Pick the closer of samples[lo] and samples[lo - 1]
        let candidates = [lo, lo - 1].filter { $0 >= 0 && $0 < samples.count }
        let best = candidates.min(by: {
            abs(samples[$0].startDate.timeIntervalSince(t)) < abs(samples[$1].startDate.timeIntervalSince(t))
        })
        guard let idx = best else { return nil }
        let s = samples[idx]
        guard s.quantity.is(compatibleWith: unit) else { return nil }
        let v = s.quantity.doubleValue(for: unit)
        return v.isFinite ? v : nil
    }
}
