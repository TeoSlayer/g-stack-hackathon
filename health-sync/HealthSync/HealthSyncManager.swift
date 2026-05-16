import Foundation
import HealthKit
import BackgroundTasks
import Combine
import os
import WidgetKit
import CoreLocation

// File-scoped logger — Sendable, nonisolated, freely usable from any closure.
private let log = Logger(subsystem: "io.vulturelabs.healthsync", category: "manager")

// One-time log helper for the (paid-only) background-delivery entitlement,
// so we don't print twenty identical warnings on launch.
private let bgDeliveryFailureLatch = NSLock()
private nonisolated(unsafe) var bgDeliveryFailureLogged = false
private func logBgDeliveryFailureOnce(err: Error) {
    bgDeliveryFailureLatch.lock()
    defer { bgDeliveryFailureLatch.unlock() }
    if !bgDeliveryFailureLogged {
        bgDeliveryFailureLogged = true
        log.warning("HealthKit background delivery unavailable: \(err.localizedDescription). Foreground observers still work; background wake-ups require the paid-Apple-Developer-only com.apple.developer.healthkit.background-delivery entitlement.")
    }
}

/// One singleton runs everything: HK reads, observer queries, anchored delta queries, sync.
///
/// The sync strategy is "per-type anchor". For each HK type we store an HKQueryAnchor
/// in UserDefaults. When an observer query fires (immediately or via background delivery),
/// we run an anchored object query from that anchor → get only the new samples → POST
/// to the pod → on success advance the anchor. If POST fails, the anchor stays put and
/// the next attempt picks up the same delta.
@MainActor
final class HealthSyncManager: ObservableObject {

    static let shared = HealthSyncManager()
    static let bgRefreshIdentifier = "io.vulturelabs.healthsync.refresh"
    static let bgProcessingIdentifier = "io.vulturelabs.healthsync.processing"

    @Published var lastSyncDate: Date?
    @Published var lastSyncResult: String = "—"
    @Published var pendingCount: Int = 0
    @Published var authorizationStatus: String = "—"
    @Published var serverReachable: Bool = false
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "http://192.168.5.66:8100"
    @Published var deviceID: String = UserDefaults.standard.string(forKey: "deviceID") ?? HealthSyncManager.defaultDeviceID()

    /// What's happening right now. Shown live in the Status hero so the UI never
    /// looks frozen during a long sync.
    @Published var currentActivity: String = "Starting up…"
    @Published var isWorking: Bool = true

    /// Daily readiness signal (overnight HRV vs 7-day personal baseline). Recomputed
    /// after every `syncAll` and surfaced on the Status hero + the widget.
    @Published var readiness: ReadinessReading = .unknown

    /// 30-day time series cache, populated once per `syncAll`. Trends, Models
    /// and the widget snapshot all read from this — saves ~12 redundant
    /// `HKStatisticsCollectionQuery` jobs per sync.
    @Published var cachedSeries: [MetricKind: MetricSeries] = [:]

    /// All seven model readings, refreshed after each `syncAll`. Status surfaces
    /// the worst non-green one inline.
    @Published var modelReadings: [ModelReading] = []

    /// Snapshot of the device's last-known location, captured at the start of each
    /// `syncAll` and attached to every `/ingest` payload. nil if permission is
    /// missing or the fix timed out.
    private var currentLocation: CLLocation?

    /// In-memory ring buffer of recent events for the activity feed.
    @Published var recentSyncs: [SyncEvent] = []
    private let maxHistory = 200

    struct SyncEvent: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let kind: String       // "sync", "ping", "observer", "notif", "boot"
        let success: Bool
        let message: String
        /// Short type identifier (e.g. "heartRate"). Nil for non-per-type events.
        let typeId: String?
        /// Samples accepted by the server for this event. Nil for non-sync events.
        let accepted: Int?
    }

    // HKHealthStore is thread-safe; making it nonisolated keeps the actor checker
    // out of the way when we touch it from HK callbacks. Module-internal so
    // `TrendsView` can run its own statistics queries without a wrapper layer.
    nonisolated let store = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []

    // MARK: transport

    /// Which sync transport is active. Persisted to UserDefaults under `"transportKind"`.
    /// Defaults to HTTP because that's the implemented one; Pilot is a stub.
    @Published var transportKind: TransportKind = {
        if let raw = UserDefaults.standard.string(forKey: "transportKind"),
           let k = TransportKind(rawValue: raw) {
            return k
        }
        return .http
    }()

    /// Pilot peer address (when `transportKind == .pilot`). Set in Settings.
    /// Normalised at load so a previously-saved colon-style address gets
    /// auto-corrected on next launch without losing the user's input.
    @Published var pilotPeerAddress: String = {
        let raw = UserDefaults.standard.string(forKey: "pilotPeerAddress") ?? ""
        return HealthSyncManager.normalizePilotAddress(raw)
    }()
    @Published var pilotPeerNodeID:  UInt32 = UInt32(UserDefaults.standard.integer(forKey: "pilotPeerNodeID"))

    // MARK: background-run telemetry
    //
    // BGTask completion is otherwise invisible to the user — the system silently
    // wakes us, we sync, and the only trace is a row in `recentSyncs`. Persist
    // last-run timestamps explicitly so Settings/Activity can answer "did
    // background refresh actually run since I last opened the app?".

    @Published var lastBackgroundRunAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "lastBackgroundRunAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    @Published var lastBackgroundRunResult: String =
        UserDefaults.standard.string(forKey: "lastBackgroundRunResult") ?? "—"
    @Published var lastBackgroundRunKind: String =
        UserDefaults.standard.string(forKey: "lastBackgroundRunKind") ?? "—"

    /// Build the active transport on demand. Each call returns a fresh value
    /// so a Settings toggle takes effect immediately on the next sync.
    private var transport: any SyncTransport {
        switch transportKind {
        case .http:
            return HTTPSyncTransport(baseURL: serverURL, deviceID: deviceID)
        case .pilot:
            return PilotSyncTransport(
                deviceID: deviceID,
                peerAddress: pilotPeerAddress,
                peerNodeID: pilotPeerNodeID
            )
        }
    }

    /// Per-type re-entrance guard. HK fires each observer once on registration, so without
    /// this `bootstrap()` would kick off `syncAll` AND ~19 observer-triggered `syncOne`s in
    /// parallel — same anchors, same samples, multi-MB bodies sent twice. One per type.
    private var inFlight: Set<String> = []

    /// Per-type throttle for *observer-triggered* syncs only. Heart-rate observers fire
    /// every ~5 s while the watch is recording — without this, the MainActor runs hot
    /// and the phone literally warms up. Manual / launch / BG syncs bypass this.
    private var lastObserverSync: [String: Date] = [:]
    private let observerThrottle: TimeInterval = 60

    /// Max samples per `/ingest` POST. After a long offline period the anchor can be far
    /// behind and a naive single-body upload balloons to 60+ MB and gets RST by the server.
    private static let chunkSize = 200

    /// Rolling backfill window. The anchored query always carries a start-date
    /// predicate so we never haul years of historical HK data through the
    /// outbox. Matches `CHUNKING.md` — 30 days covers every on-device model at
    /// full quality; the heatmap + CUSUM grow forward as new samples arrive.
    static let backfillWindowDays: Int = 30

    /// Window the user gets when they pick "Full backfill" from the manual
    /// sync menu — one year covers seasonality, gives every model enough room
    /// to train its baseline, and stays under the Pilot 60-KB-per-envelope
    /// cap since `chunkSize` paging is unaffected.
    static let deepBackfillWindowDays: Int = 365

    /// Per-run override for `anchoredQuery`'s cutoff. Reset to nil after each
    /// `syncAll` so a deep-backfill sweep doesn't accidentally affect the next
    /// observer-driven incremental sync.
    private var activeBackfillDays: Int = HealthSyncManager.backfillWindowDays

    static func defaultDeviceID() -> String {
        let model = UIDevice.current.model
        let name  = UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
        return "\(model)-\(name)"
    }

    // MARK: bootstrap

    /// Set on first successful call so re-entry from a second `.task` (e.g.
    /// onboarding triggered HK auth, then ContentView's `.task` fires) is a
    /// no-op instead of re-prompting / re-installing observers.
    private var didBootstrap = false

    func bootstrap() async {
        if didBootstrap { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = "Not available"
            currentActivity = "HealthKit unavailable"
            isWorking = false
            recordEvent(kind: "boot", success: false, message: "HealthKit not available on this device")
            return
        }

        currentActivity = "Requesting HealthKit permission…"
        recordEvent(kind: "boot", success: true, message: "Requesting HealthKit permission")

        // Ask for permission to read all the types we care about.
        let types = HKTypes.allReadTypes()
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            authorizationStatus = "Granted (some)"
            recordEvent(kind: "boot", success: true, message: "HealthKit auth dialog dismissed")
        } catch {
            log.error("HK auth failed: \(error.localizedDescription)")
            authorizationStatus = "Denied: \(error.localizedDescription)"
            currentActivity = "HealthKit auth failed"
            isWorking = false
            recordEvent(kind: "boot", success: false, message: "HealthKit auth failed: \(error.localizedDescription)")
            return
        }

        currentActivity = "Installing observers…"
        startObservers()
        scheduleBackgroundRefresh()
        didBootstrap = true
        // Prompt for location once, right after HK — the user is already in
        // "granting permissions" mode and a second dialog reads as expected.
        LocationProvider.shared.requestAuth()
        // Boot the Pilot daemon and seed its peer config. State stays observable
        // on PilotBoot.shared regardless of which transport is currently active —
        // user can flip to Pilot in Settings any time.
        PilotBoot.shared.setPeer(address: pilotPeerAddress, nodeID: pilotPeerNodeID)
        Task {
            await PilotBoot.shared.start()
            _ = await PilotBoot.shared.ensureTrusted()
        }
        recordEvent(kind: "boot", success: true, message: "Observers installed, BG tasks scheduled")
        // Compute readiness + models *eagerly* from HealthKit, in parallel with
        // the launch sync. The user sees the Status / Models tabs populated
        // within ~1 s of launch instead of waiting for syncAll to finish.
        Task {
            currentActivity = "Computing readiness from HealthKit…"
            readiness = await Readiness.compute(store: store, cache: cachedSeries)
            await refreshDerivedState()
        }
        Task { await pingServer() }
        Task { await syncAll(reason: "launch") }
    }

    // MARK: observers (live + background delivery)

    private func startObservers() {
        // Stop any previous run before re-installing.
        for q in observerQueries { store.stop(q) }
        observerQueries.removeAll()

        for id in HKTypes.quantityIdentifiers {
            guard let t = HKObjectType.quantityType(forIdentifier: id) else { continue }
            installObserver(for: t)
        }
        for id in HKTypes.categoryIdentifiers {
            guard let t = HKObjectType.categoryType(forIdentifier: id) else { continue }
            installObserver(for: t)
        }
        installObserver(for: HKObjectType.workoutType())
    }

    private func installObserver(for type: HKSampleType) {
        let q = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, err in
            if let err = err {
                log.warning("observer error for \(type.identifier): \(err.localizedDescription)")
                completion()
                return
            }
            Task { @MainActor [weak self] in
                guard let self = self else { completion(); return }
                // Throttle observer-driven syncs so HR's ~5 s firing rate doesn't
                // burn the CPU. Any newly-arrived samples will still be picked up
                // on the *next* tick (or on launch/manual sync), since anchors
                // persist across the gap.
                let now = Date()
                if let last = self.lastObserverSync[type.identifier],
                   now.timeIntervalSince(last) < self.observerThrottle {
                    completion()
                    return
                }
                self.lastObserverSync[type.identifier] = now
                await self.syncOne(type: type, reason: "observer")
                completion()  // tell HK we've processed the change
            }
        }
        store.execute(q)
        observerQueries.append(q)

        // Background delivery requires the paid-developer-only
        // `com.apple.developer.healthkit.background-delivery` entitlement.
        // Personal Team can't grant it — we still want observer queries to
        // fire while the app is in the foreground, so just no-op on failure
        // and log the first failure only.
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, err in
            if let err = err {
                logBgDeliveryFailureOnce(err: err)
            }
        }
    }

    // MARK: sync

    /// Sync every known type sequentially. Called from launch, BG refresh, and the UI button.
    ///
    /// - Parameters:
    ///   - backfillDays: override the rolling 30-day window for this run (e.g.
    ///     365 from a "Full backfill" tap). Reset to default after this run.
    ///   - resetAnchors: drop every per-type HK anchor before syncing, forcing
    ///     `anchoredQuery` to re-walk the full window. Without this, a deep
    ///     backfill no-ops because the anchor is already past the new cutoff.
    func syncAll(reason: String,
                 backfillDays: Int? = nil,
                 resetAnchors: Bool = false) async {
        log.info("syncAll: \(reason) (backfillDays=\(backfillDays ?? -1) resetAnchors=\(resetAnchors))")
        isWorking = true
        activeBackfillDays = backfillDays ?? Self.backfillWindowDays
        if resetAnchors {
            resetAllAnchors()
            recordEvent(kind: "sync", success: true,
                        message: "anchors reset for deep backfill (\(activeBackfillDays)d)")
        }
        defer {
            isWorking = false
            currentActivity = "Idle"
            activeBackfillDays = Self.backfillWindowDays
        }

        currentActivity = "Pinging server…"
        // Kick off a location fix in parallel with the ping — both finish in <5 s.
        async let locationFix = LocationProvider.shared.currentFix()
        await pingServer()
        currentLocation = await locationFix
        guard serverReachable else {
            lastSyncResult = "server unreachable"
            currentActivity = "Server unreachable — paused"
            recordEvent(kind: "sync", success: false, message: "server unreachable (\(reason))")
            await NotificationManager.shared.evaluateSyncHealth(
                lastSuccess: lastSyncDate, serverReachable: false)
            return
        }

        let allIdentifiers = HKTypes.quantityIdentifiers.map { $0.rawValue }
            + HKTypes.categoryIdentifiers.map { $0.rawValue }
            + ["Workout"]
        recordEvent(kind: "sync", success: true, message: "syncAll start (\(reason), \(allIdentifiers.count) types)")

        var grandTotal = 0
        var index = 0
        let total = allIdentifiers.count
        for id in HKTypes.quantityIdentifiers {
            if let t = HKObjectType.quantityType(forIdentifier: id) {
                index += 1
                currentActivity = "Syncing \(shortName(t)) (\(index)/\(total))…"
                grandTotal += await syncOne(type: t, reason: reason)
            }
        }
        for id in HKTypes.categoryIdentifiers {
            if let t = HKObjectType.categoryType(forIdentifier: id) {
                index += 1
                currentActivity = "Syncing \(shortName(t)) (\(index)/\(total))…"
                grandTotal += await syncOne(type: t, reason: reason)
            }
        }
        index += 1
        currentActivity = "Syncing Workout (\(index)/\(total))…"
        grandTotal += await syncOne(type: HKObjectType.workoutType(), reason: reason)

        lastSyncDate = Date()
        lastSyncResult = "+\(grandTotal) samples (\(reason))"
        recordEvent(kind: "sync", success: true, message: "syncAll done: +\(grandTotal) samples (\(reason))")
        await NotificationManager.shared.evaluateSyncHealth(
            lastSuccess: lastSyncDate, serverReachable: true)
        let previousBand = readiness.band
        readiness = await Readiness.compute(store: store, cache: cachedSeries)
        await NotificationManager.shared.evaluateReadiness(
            previous: previousBand, current: readiness)
        await refreshDerivedState()
        await publishWidgetSnapshot(lastBatchSamples: grandTotal)
    }

    /// Populate the manager-level caches that views and the widget all read from.
    /// One pass replaces what used to be 3+ duplicate query batches across views.
    @MainActor
    func refreshDerivedState() async {
        async let h  = TimeSeries.compute(kind: .hrv,   days: 30, forecastDays: 7, store: store)
        async let r  = TimeSeries.compute(kind: .rhr,   days: 30, forecastDays: 7, store: store)
        async let s  = TimeSeries.compute(kind: .sleep, days: 30, forecastDays: 7, store: store)
        async let st = TimeSeries.compute(kind: .steps, days: 30, forecastDays: 7, store: store)
        cachedSeries = await [.hrv: h, .rhr: r, .sleep: s, .steps: st]
        modelReadings = await Models.computeAll(store: store, cache: cachedSeries)
    }

    /// Write a snapshot blob to App-Group `UserDefaults` and ask WidgetKit to
    /// refresh. Pulls 30-day daily history + 7-day forecasts so the medium/large
    /// widget families can render sparklines without needing HK access of their own.
    private func publishWidgetSnapshot(lastBatchSamples: Int) async {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let last24 = recentSyncs
            .filter { $0.kind == "sync" && $0.success && $0.date >= cutoff }
            .compactMap { $0.accepted }
            .reduce(0, +)

        // Read from the cache populated by `refreshDerivedState()` instead of
        // re-running 4 × 30-day stats queries here.
        let h  = cachedSeries[.hrv]   ?? MetricSeries(kind: .hrv,   history: [], smoothed: [], forecast: [], trendPerDay: 0)
        let r  = cachedSeries[.rhr]   ?? MetricSeries(kind: .rhr,   history: [], smoothed: [], forecast: [], trendPerDay: 0)
        let sl = cachedSeries[.sleep] ?? MetricSeries(kind: .sleep, history: [], smoothed: [], forecast: [], trendPerDay: 0)
        let st = cachedSeries[.steps] ?? MetricSeries(kind: .steps, history: [], smoothed: [], forecast: [], trendPerDay: 0)

        func toMini(_ pts: [MetricPoint]) -> [MiniPoint] {
            pts.map { MiniPoint(date: $0.date, value: $0.value) }
        }

        let snap = WidgetSnapshot(
            lastSyncDate: lastSyncDate,
            lastSampleCount: lastBatchSamples,
            totalSamplesLast24h: last24,
            serverReachable: serverReachable,
            readinessScore: readiness.band == .unknown ? nil : readiness.score,
            readinessAdvice: readiness.band == .unknown ? nil : readiness.advice,
            readinessBand: readiness.band.rawValue,
            hrvSeries:     toMini(h.history),
            rhrSeries:     toMini(r.history),
            sleepSeries:   toMini(sl.history),
            stepsSeries:   toMini(st.history),
            hrvForecast:   toMini(h.forecast),
            rhrForecast:   toMini(r.forecast),
            sleepForecast: toMini(sl.forecast),
            stepsForecast: toMini(st.forecast)
        )
        WidgetStore.write(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func shortName(_ t: HKSampleType) -> String {
        t.identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
    }

    /// Per-ingest metadata sent on the JSON body. Currently just location, but the
    /// dict is open-ended so the pod can route on whatever else we attach later.
    private func buildIngestMetadata() -> [String: Any] {
        var meta: [String: Any] = [:]
        if let loc = currentLocation {
            meta["location"] = [
                "lat":         loc.coordinate.latitude,
                "lon":         loc.coordinate.longitude,
                "accuracy_m":  loc.horizontalAccuracy.isFinite ? loc.horizontalAccuracy : -1,
                "altitude_m":  loc.altitude.isFinite ? loc.altitude : 0,
                "timestamp":   loc.timestamp.timeIntervalSince1970,
            ]
        }
        return meta
    }

    private func recordEvent(kind: String, success: Bool, message: String,
                             typeId: String? = nil, accepted: Int? = nil) {
        recentSyncs.insert(
            SyncEvent(date: Date(), kind: kind, success: success, message: message,
                      typeId: typeId, accepted: accepted),
            at: 0
        )
        if recentSyncs.count > maxHistory { recentSyncs.removeLast(recentSyncs.count - maxHistory) }
    }

    /// Sync a single HK type. Returns total samples accepted across all pages.
    ///
    /// Pages the HK anchored query (1000 samples at a time) and **advances the anchor
    /// after every successful page**. A failure mid-backfill now only loses the current
    /// page's progress, not the entire backlog — without this, a single chunk timeout
    /// in the middle of 1476 chunks restarts from zero on every sync.
    @discardableResult
    func syncOne(type: HKSampleType, reason: String) async -> Int {
        guard inFlight.insert(type.identifier).inserted else { return 0 }
        defer { inFlight.remove(type.identifier) }

        let anchorKey = "anchor:\(type.identifier)"
        let label = shortName(type)
        let hkPageSize = 1000
        var totalAccepted = 0
        var totalDuplicate = 0
        var totalPosted = 0

        while true {
            let anchor = readAnchor(key: anchorKey)
            let (samples, newAnchor) = await anchoredQuery(type: type, anchor: anchor, limit: hkPageSize)
            if samples.isEmpty { break }

            let payload: [[String: Any]] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: samples.compactMap { Self.encode(sample: $0) })
                }
            }
            // If encode dropped everything (NaN/Inf/incompatible unit), still advance
            // the anchor so we don't re-query the same unencodable samples forever.
            if payload.isEmpty {
                writeAnchor(key: anchorKey, newAnchor)
                if samples.count < hkPageSize { break }
                continue
            }

            var pageAccepted = 0
            var pageDuplicate = 0
            let batches = stride(from: 0, to: payload.count, by: Self.chunkSize).map {
                Array(payload[$0..<min($0 + Self.chunkSize, payload.count)])
            }
            let meta = buildIngestMetadata()
            var pageOK = true
            for (idx, batch) in batches.enumerated() {
                do {
                    let result = try await transport.ingest(samples: batch, metadata: meta)
                    pageAccepted += result.accepted
                    pageDuplicate += result.duplicate
                } catch {
                    let msg = "✗ \(label) page chunk \(idx + 1)/\(batches.count): \(error.localizedDescription)"
                    log.warning("\(msg) — anchor unchanged for this page, will retry")
                    recordEvent(kind: "sync", success: false, message: msg, typeId: label, accepted: pageAccepted)
                    pageOK = false
                    break
                }
                await Task.yield()
            }

            totalAccepted += pageAccepted
            totalDuplicate += pageDuplicate
            totalPosted += payload.count

            if !pageOK { return totalAccepted }

            // Entire page succeeded — commit the anchor so this page is durable.
            writeAnchor(key: anchorKey, newAnchor)
            if samples.count < hkPageSize { break }
        }

        if totalPosted > 0 {
            log.info("\(type.identifier): posted \(totalPosted) (\(totalAccepted) accepted, \(totalDuplicate) dup)")
            recordEvent(kind: "sync", success: true,
                        message: "✓ \(label): +\(totalAccepted) accepted, \(totalDuplicate) dup (\(totalPosted) sent)",
                        typeId: label, accepted: totalAccepted)
        }
        return totalAccepted
    }

    private func anchoredQuery(type: HKSampleType, anchor: HKQueryAnchor?, limit: Int) async -> ([HKSample], HKQueryAnchor?) {
        // ALWAYS clamp queries to the rolling backfill window. Without this,
        // HKAnchoredObjectQuery happily walks back years on a fresh anchor —
        // HeartRate alone can be hundreds of thousands of samples that we
        // then try to ship one page at a time, taking hours. Window can be
        // widened per-run (see `syncAll(backfillDays:)`).
        let cutoff = Date().addingTimeInterval(-Double(activeBackfillDays) * 86_400)
        let predicate = HKQuery.predicateForSamples(
            withStart: cutoff,
            end:       nil,
            options:   .strictStartDate
        )
        return await withCheckedContinuation { cont in
            let q = HKAnchoredObjectQuery(
                type: type, predicate: predicate, anchor: anchor,
                limit: limit
            ) { _, samples, _, newAnchor, err in
                if let err = err {
                    log.warning("anchored query error \(type.identifier): \(err.localizedDescription)")
                }
                cont.resume(returning: (samples ?? [], newAnchor))
            }
            store.execute(q)
        }
    }

    private func readAnchor(key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let a = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
            return nil
        }
        return a
    }

    private func writeAnchor(key: String, _ anchor: HKQueryAnchor?) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Wipe every `anchor:<HKTypeIdentifier>` UserDefaults entry. Called by
    /// deep-backfill syncs so the next anchored query starts from the wider
    /// cutoff rather than skipping forward from a stale anchor inside it.
    private func resetAllAnchors() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("anchor:") }
        for k in keys { defaults.removeObject(forKey: k) }
        log.info("reset \(keys.count) HK anchors for deep backfill")
    }

    /// `nonisolated` so we can call it from a background queue. Filters NaN/Inf
    /// (JSONSerialization raises an NSException on them — unrecoverable in pure
    /// Swift) and unit mismatches (raised "degC vs %"-style NSException too).
    nonisolated static func encode(sample: HKSample) -> [String: Any]? {
        let startTs = sample.startDate.timeIntervalSince1970
        let endTs   = sample.endDate.timeIntervalSince1970
        // Defensive — Apple's HK shouldn't hand us NaN-stamped samples but
        // JSON serialization traps on them so we belt-and-brace this.
        guard startTs.isFinite, endTs.isFinite else { return nil }
        var dict: [String: Any] = [
            "type":       HKTypes.canonicalId(for: sample.sampleType),
            "source":     sample.sourceRevision.source.name,
            "start_utc":  startTs,
            "end_utc":    endTs,
            "uuid":       sample.uuid.uuidString,
        ]
        if let device = sample.device?.name {
            dict["metadata"] = ["device": device]
        }
        if let q = sample as? HKQuantitySample {
            let unit = HKTypes.preferredUnit(for: q.quantityType)
            guard q.quantity.is(compatibleWith: unit) else { return nil }
            let value = q.quantity.doubleValue(for: unit)
            guard value.isFinite else { return nil }
            dict["unit"]  = unit.unitString
            dict["value"] = value
        } else if let c = sample as? HKCategorySample {
            dict["unit"] = "category"
            var meta: [String: Any] = [:]
            for (k, v) in c.metadata ?? [:] { meta[k] = "\(v)" }
            dict["value_json"] = ["categoryValue": c.value, "metadata": meta]
        } else if let w = sample as? HKWorkout {
            dict["unit"] = "workout"
            var wj: [String: Any] = [
                "activityType": w.workoutActivityType.rawValue,
                "duration_s":   w.duration.isFinite ? w.duration : 0,
            ]
            if let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()), kcal.isFinite {
                wj["totalEnergyBurned_kcal"] = kcal
            }
            if let m = w.totalDistance?.doubleValue(for: .meter()), m.isFinite {
                wj["totalDistance_m"] = m
            }
            dict["value_json"] = wj
        } else {
            return nil
        }
        return dict
    }

    /// `userInitiated: true` for taps from Activity / Settings — emits an
    /// event every time so the user sees their tap landed. Background callers
    /// (launch, BG refresh, ensureRunning) still only log on state transitions
    /// to avoid spamming the activity log every 60 s.
    func pingServer(userInitiated: Bool = false) async {
        let ok = await transport.ping()
        let wasReachable = serverReachable
        serverReachable = ok
        if userInitiated {
            recordEvent(kind: "ping", success: ok,
                        message: ok ? "\(transportKind.displayName) reachable"
                                    : "\(transportKind.displayName) unreachable")
        } else if ok && !wasReachable {
            recordEvent(kind: "ping", success: true,
                        message: "\(transportKind.displayName) reachable")
        } else if !ok && wasReachable {
            recordEvent(kind: "ping", success: false,
                        message: "\(transportKind.displayName) unreachable")
        }
    }

    // MARK: background tasks

    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.bgRefreshIdentifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)  // 15 min
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            // Common in the simulator (BG tasks unsupported) and after the
            // user disables Background App Refresh in Settings. Log so the
            // diagnostics tab can show why sync isn't running in background.
            log.warning("BG refresh submit failed: \(error.localizedDescription)")
        }

        let proc = BGProcessingTaskRequest(identifier: Self.bgProcessingIdentifier)
        proc.requiresExternalPower = false
        proc.requiresNetworkConnectivity = true
        proc.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)  // 1h
        do {
            try BGTaskScheduler.shared.submit(proc)
        } catch {
            log.warning("BG processing submit failed: \(error.localizedDescription)")
        }
    }

    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()  // always reschedule
        let op = Task {
            await PilotBoot.shared.ensureRunning()
            await syncAll(reason: "bg-refresh")
        }
        task.expirationHandler = { op.cancel() }
        Task {
            _ = await op.value
            await recordBackgroundRun(kind: "refresh", expired: op.isCancelled)
            task.setTaskCompleted(success: !op.isCancelled)
        }
    }

    func handleBackgroundProcessing(_ task: BGProcessingTask) {
        scheduleBackgroundRefresh()
        let op = Task {
            await PilotBoot.shared.ensureRunning()
            await syncAll(reason: "bg-processing")
        }
        task.expirationHandler = { op.cancel() }
        Task {
            _ = await op.value
            await recordBackgroundRun(kind: "processing", expired: op.isCancelled)
            task.setTaskCompleted(success: !op.isCancelled)
        }
    }

    /// Persist that a BGTask just finished so the user can see "last bg run
    /// 23 min ago" in Activity. `expired` distinguishes the two ways a BGTask
    /// can finish — clean exit vs iOS hitting the expiration handler.
    private func recordBackgroundRun(kind: String, expired: Bool) async {
        let now = Date()
        lastBackgroundRunAt = now
        lastBackgroundRunKind = kind
        lastBackgroundRunResult = expired ? "expired"
                                          : (lastSyncResult.isEmpty ? "ok" : lastSyncResult)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "lastBackgroundRunAt")
        UserDefaults.standard.set(lastBackgroundRunResult, forKey: "lastBackgroundRunResult")
        UserDefaults.standard.set(kind, forKey: "lastBackgroundRunKind")
    }

    // MARK: settings

    func updateServerURL(_ url: String) {
        serverURL = url
        UserDefaults.standard.set(url, forKey: "serverURL")
        Task { await pingServer() }
    }

    func updateDeviceID(_ id: String) {
        deviceID = id
        UserDefaults.standard.set(id, forKey: "deviceID")
    }

    func updateTransport(_ kind: TransportKind) {
        transportKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: "transportKind")
        recordEvent(kind: "boot", success: true,
                    message: "transport switched to \(kind.displayName)")
        Task { await pingServer() }
    }

    func updatePilotPeer(address: String, nodeID: UInt32) {
        // Normalise common entry mistakes. Pilot virtual addresses look like
        // `N:HHHH.HHHH.HHHH` — one colon after the network number then three
        // *dot*-separated hex groups. People paste them with colons throughout
        // (IPv6-style); convert that here so the daemon doesn't reject it.
        let normalized = Self.normalizePilotAddress(address)
        pilotPeerAddress = normalized
        pilotPeerNodeID  = nodeID
        UserDefaults.standard.set(normalized, forKey: "pilotPeerAddress")
        UserDefaults.standard.set(Int(nodeID), forKey: "pilotPeerNodeID")
        PilotBoot.shared.setPeer(address: normalized, nodeID: nodeID)
        recordEvent(kind: "boot", success: true,
                    message: "Pilot peer set: \(normalized) (#\(nodeID))")
        Task {
            _ = await PilotBoot.shared.ensureTrusted()
            if transportKind == .pilot { await pingServer() }
        }
    }

    /// `0:0000:0002:74EE` → `0:0000.0002.74EE`. Also strips whitespace and
    /// upcases hex digits so the on-disk format stays canonical.
    static func normalizePilotAddress(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: ":")
        if parts.count == 4 {
            // User typed all colons — rewrite as N:H.H.H
            return "\(parts[0]):\(parts[1]).\(parts[2]).\(parts[3])".uppercased()
                .replacingOccurrences(of: "0X", with: "0x")
        }
        return trimmed
    }

    /// Wipe the configured Pilot peer. If the active transport was Pilot,
    /// also flips back to HTTP so the user isn't left in a stuck "Pilot
    /// selected with no peer" state.
    func clearPilotPeer() {
        pilotPeerAddress = ""
        pilotPeerNodeID  = 0
        UserDefaults.standard.removeObject(forKey: "pilotPeerAddress")
        UserDefaults.standard.removeObject(forKey: "pilotPeerNodeID")
        PilotBoot.shared.setPeer(address: "", nodeID: 0)
        recordEvent(kind: "boot", success: true, message: "Pilot peer removed")
        if transportKind == .pilot {
            updateTransport(.http)
        }
    }

    /// True if Pilot is a valid transport choice right now. Used by Settings
    /// to gate the "Pilot" picker option — selecting it without a peer makes
    /// no sense and is the source of half the support questions.
    var pilotConfigured: Bool {
        !pilotPeerAddress.isEmpty && pilotPeerNodeID != 0
    }
}

import UIKit  // for UIDevice
