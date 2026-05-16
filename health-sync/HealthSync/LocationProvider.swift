import Foundation
import CoreLocation

/// One-shot location fixes with a short cache, used to tag each `/ingest`
/// payload with where the phone was at sync time. No continuous tracking —
/// `CLLocationManager.requestLocation()` delivers a single fix per call.
///
/// Requires `NSLocationWhenInUseUsageDescription` in Info.plist. Background
/// syncs (via `BGAppRefreshTask`) inherit the foreground authorization grant
/// and can still receive a fix while the BG task is running.
final class LocationProvider: NSObject, @unchecked Sendable {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var pending: CheckedContinuation<CLLocation?, Never>?
    private var cached: CLLocation?
    private var cachedAt: Date?
    private let cacheTTL: TimeInterval = 5 * 60   // re-fetch at most every 5 min

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters  // coarse — we just want "where", not "exactly where"
    }

    var authStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// Idempotent. Call once near app start. If status is `.notDetermined`,
    /// this triggers the system permission prompt.
    func requestAuth() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Returns the most recent fix, or requests a new one. Returns `nil` if
    /// permission is missing or the request times out.
    func currentFix(maxAge: TimeInterval = 300, timeout: TimeInterval = 5) async -> CLLocation? {
        lock.lock()
        if let c = cached, let t = cachedAt, Date().timeIntervalSince(t) < maxAge {
            lock.unlock()
            return c
        }
        if pending != nil {
            lock.unlock()
            // Another fix in flight — poll the cache rather than queue another continuation.
            for _ in 0..<Int(timeout * 10) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                lock.lock()
                if let c = cached, let t = cachedAt, Date().timeIntervalSince(t) < maxAge {
                    lock.unlock()
                    return c
                }
                lock.unlock()
            }
            return nil
        }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        return await withCheckedContinuation { cont in
            lock.lock()
            pending = cont
            lock.unlock()
            manager.requestLocation()
            // Hard timeout — CL occasionally never delivers in poor sky conditions.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with location: CLLocation?) {
        lock.lock()
        let cont = pending
        pending = nil
        if let loc = location {
            cached = loc
            cachedAt = Date()
        }
        lock.unlock()
        cont?.resume(returning: location)
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // No action — callers re-check `authStatus` next time around.
    }
}
