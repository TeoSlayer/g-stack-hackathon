import Foundation
import HealthKit
import CoreLocation

/// One observation: a metric value at a place at a time.
struct LocatedReading: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let metric: MapMetric
    let value: Double
}

/// Union of every place we can derive a (location, HK value) pair from.
/// Currently:
///   • HRV samples paired with the nearest geotagged photo (±2h window)
///   • HR + speed from outdoor workout routes (HKWorkoutRoute)
///
/// Going forward, CLVisits monitoring will add a third source. For now this
/// retroactively covers everywhere you took a photo or recorded an outdoor
/// workout.
enum LocationSources {

    /// Returns all readings across all available sources in the given window.
    static func fetchAll(daysBack: Int, store: HKHealthStore) async -> [LocatedReading] {
        async let workout = workoutRouteReadings(daysBack: daysBack, store: store)
        async let photoHRV = photoMatchedSamples(
            identifier: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            metric: .hrv, daysBack: daysBack, store: store)
        async let photoRHR = photoMatchedSamples(
            identifier: .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            metric: .rhr, daysBack: daysBack, store: store)
        async let photoHR  = photoMatchedSamples(
            identifier: .heartRate,
            unit: .count().unitDivided(by: .minute()),
            metric: .heartRate, daysBack: daysBack, store: store)
        let (w, h, r, hr) = await (workout, photoHRV, photoRHR, photoHR)
        return w + h + r + hr
    }

    // MARK: - Workout route source (HR + speed per GPS point)

    private static func workoutRouteReadings(daysBack: Int, store: HKHealthStore) async -> [LocatedReading] {
        let samples = await WorkoutRoutes.fetchSamples(daysBack: daysBack, store: store)
        var out: [LocatedReading] = []
        for s in samples {
            if let hr = s.heartRate {
                out.append(.init(coordinate: s.coordinate, timestamp: s.timestamp,
                                 metric: .heartRate, value: hr))
            }
            if let v = s.speedMPS {
                out.append(.init(coordinate: s.coordinate, timestamp: s.timestamp,
                                 metric: .speed, value: v))
            }
        }
        return out
    }

    // MARK: - Photos-joined HK sample source

    /// Pull HK samples for one identifier, join each to the nearest geotagged
    /// photo within ±2 h. Produces one LocatedReading per matched sample.
    private static func photoMatchedSamples(identifier: HKQuantityTypeIdentifier,
                                            unit: HKUnit, metric: MapMetric,
                                            daysBack: Int, store: HKHealthStore) async -> [LocatedReading] {
        guard let t = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let end = Date()
        let start = end.addingTimeInterval(-Double(daysBack) * 86400)
        async let photosAsync = PhotosLocationProvider.fetchGeotaggedPhotos(start: start, end: end)
        async let samplesAsync = hkSamples(of: t, start: start, end: end, store: store)
        let (photos, samples) = await (photosAsync, samplesAsync)
        guard !photos.isEmpty, !samples.isEmpty else { return [] }
        let maxOffset: TimeInterval = 2 * 3600
        var out: [LocatedReading] = []
        out.reserveCapacity(samples.count)
        for s in samples {
            guard let photo = nearestPhoto(to: s.startDate, photos: photos, maxOffset: maxOffset),
                  s.quantity.is(compatibleWith: unit) else { continue }
            let v = s.quantity.doubleValue(for: unit)
            guard v.isFinite else { continue }
            out.append(.init(
                coordinate: photo.location.coordinate,
                timestamp: s.startDate,
                metric: metric, value: v
            ))
        }
        return out
    }

    private static func hkSamples(of type: HKQuantityType, start: Date, end: Date,
                                  store: HKHealthStore) async -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKQuantitySample]) ?? [])
            }
            store.execute(q)
        }
    }
}

// MARK: - Hex aggregation against LocatedReading

extension HexAgg {
    /// Bin readings filtered by metric; mean value per hex cell.
    static func aggregate(readings: [LocatedReading], metric: MapMetric,
                          edgeSize: Double) -> [HexCell] {
        let filtered = readings.filter {
            $0.metric == metric || (metric == .visits)  // density counts everything
        }
        guard let firstCoord = filtered.first?.coordinate else { return [] }
        let origin = firstCoord
        var groups: [HexCoord: [LocatedReading]] = [:]
        for r in filtered {
            let h = HexGrid.hex(for: r.coordinate, origin: origin, edgeSize: edgeSize)
            groups[h, default: []].append(r)
        }
        return groups.map { coord, members in
            let value: Double? = {
                if metric == .visits { return Double(members.count) }
                let vs = members.map(\.value)
                return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
            }()
            return HexCell(
                id: coord,
                polygon: HexGrid.corners(of: coord, origin: origin, edgeSize: edgeSize),
                center: origin,
                count: members.count,
                value: value
            )
        }
    }
}
