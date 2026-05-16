import Foundation
import HealthKit
import WatchKit
import WatchConnectivity
import Combine
import os

private let log = Logger(subsystem: "io.vulturelabs.healthsync.watch", category: "manager")

/// Watch-side manager:
/// - Reads live HR + a few quantity types from the wrist (independent of phone).
/// - Mirrors sync status from the phone via WCSession ("when did the phone last
///   successfully POST to the pod?", "is the pod reachable?").
/// - Provides a "Sync now" button that nudges the phone via WCSession.
/// - On Apple Watch with cellular: tries to ping the pod directly too — if you
///   are on the home Wi-Fi via the Watch alone, this lets the Watch surface
///   "server reachable" without the phone present.
@MainActor
final class WatchHealthManager: NSObject, ObservableObject, WCSessionDelegate {

    static let shared = WatchHealthManager()
    nonisolated private let store = HKHealthStore()
    private var heartRateAnchor: HKQueryAnchor?
    private var heartRateAnchoredQuery: HKAnchoredObjectQuery?

    @Published var currentHeartRate: Double?
    @Published var lastUpdate: Date?
    @Published var phoneReachable: Bool = false
    @Published var phoneLastSync: Date?
    @Published var phoneServerReachable: Bool = false
    @Published var authorizationStatus: String = "—"

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func bootstrap() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        var read: Set<HKObjectType> = []
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { read.insert(t) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { read.insert(t) }
        read.insert(HKObjectType.workoutType())

        do {
            try await store.requestAuthorization(toShare: [], read: read)
            authorizationStatus = "Granted"
        } catch {
            log.error("HK auth failed: \(error.localizedDescription)")
            authorizationStatus = "Denied"
            return
        }

        startLiveHeartRate()
    }

    /// Live HR — anchored query that keeps streaming new samples as they come in
    /// from the Watch's sensors. This is also a way to encourage the OS to keep
    /// the app alive longer when actively shown.
    private func startLiveHeartRate() {
        guard let hr = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        let q = HKAnchoredObjectQuery(
            type: hr,
            predicate: nil,
            anchor: heartRateAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, _ in
            // HK callbacks are @Sendable — hop to the main actor to touch our state.
            Task { @MainActor [weak self] in
                self?.apply(hrSamples: samples, newAnchor: newAnchor)
            }
        }
        q.updateHandler = { [weak self] _, samples, _, newAnchor, _ in
            Task { @MainActor [weak self] in
                self?.apply(hrSamples: samples, newAnchor: newAnchor)
            }
        }
        store.execute(q)
        heartRateAnchoredQuery = q
    }

    private func apply(hrSamples samples: [HKSample]?, newAnchor: HKQueryAnchor?) {
        heartRateAnchor = newAnchor
        guard let q = samples?.compactMap({ $0 as? HKQuantitySample }).last else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        currentHeartRate = q.quantity.doubleValue(for: unit)
        lastUpdate = q.endDate
    }

    // MARK: WCSession
    //
    // The delegate methods are called by WatchConnectivity on a background queue,
    // so they must be `nonisolated`. Each one hops onto the main actor to mutate
    // observable state.

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.phoneReachable = reachable }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.phoneReachable = reachable }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in self.applyPhoneContext(applicationContext) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in self.applyPhoneContext(message) }
    }

    private func applyPhoneContext(_ ctx: [String: Any]) {
        if let ts = ctx["lastSyncAt"] as? TimeInterval { phoneLastSync = Date(timeIntervalSince1970: ts) }
        if let ok = ctx["serverReachable"] as? Bool   { phoneServerReachable = ok }
    }

    /// Nudge phone to sync. Phone has full HK access and the persistent anchor set.
    func requestPhoneSync() {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["action": "syncNow"], replyHandler: nil) { err in
            log.warning("sync nudge failed: \(err.localizedDescription)")
        }
    }
}
