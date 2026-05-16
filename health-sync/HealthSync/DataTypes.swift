import HealthKit

/// Which HealthKit types this app reads and syncs.
/// Add/remove freely. The pod schema is generic (single samples table)
/// so new types don't require a server-side change.
enum HKTypes {

    static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .oxygenSaturation,
        .respiratoryRate,
        .bodyTemperature,
        .stepCount,
        .distanceWalkingRunning,
        .distanceCycling,
        .flightsClimbed,
        .activeEnergyBurned,
        .basalEnergyBurned,
        .appleExerciseTime,
        .appleStandTime,
        .vo2Max,
        .bodyMass,
        .timeInDaylight,              // iOS 17+: Apple Watch infers via UV / ambient light + GPS
        .environmentalAudioExposure,  // dBASPL, used for acoustic load metric
    ]

    static let categoryIdentifiers: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis,
        .mindfulSession,
        .appleStandHour,
    ]

    static func allReadTypes() -> Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        for id in quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        for id in categoryIdentifiers {
            if let t = HKObjectType.categoryType(forIdentifier: id) { set.insert(t) }
        }
        set.insert(HKObjectType.workoutType())
        return set
    }

    /// Canonical string id used in the JSON payload and the server DB.
    static func canonicalId(for sampleType: HKSampleType) -> String {
        if let q = sampleType as? HKQuantityType {
            // identifier like "HKQuantityTypeIdentifierHeartRate" → "heartRate"
            return q.identifier
                .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .prefix(1).lowercased() + q.identifier
                .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .dropFirst()
        }
        if let c = sampleType as? HKCategoryType {
            return c.identifier
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                .prefix(1).lowercased() + c.identifier
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                .dropFirst()
        }
        if sampleType is HKWorkoutType {
            return "workout"
        }
        return sampleType.identifier
    }

    /// Preferred unit per HK quantity type.
    static func preferredUnit(for q: HKQuantityType) -> HKUnit {
        switch q.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return HKUnit.secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return HKUnit.percent()
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
            return HKUnit.degreeCelsius()
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return HKUnit.count()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue:
            return HKUnit.meter()
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return HKUnit.kilocalorie()
        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue,
             HKQuantityTypeIdentifier.timeInDaylight.rawValue:
            return HKUnit.minute()
        case HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue:
            return HKUnit(from: "dBASPL")
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit(from: "ml/kg*min")
        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)
        default:
            return HKUnit.count()
        }
    }
}
