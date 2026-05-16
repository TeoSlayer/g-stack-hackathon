import Foundation
import WatchConnectivity

/// Phone-side adapter. Drop this file into the iOS target. It listens for the
/// Watch's "syncNow" nudges and publishes status back so the watch UI can show it.
@MainActor
final class WCSessionBridge: NSObject, WCSessionDelegate {

    static let shared = WCSessionBridge()
    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Push the current sync status to the Watch as an application context
    /// (most-recent state, replaces any pending one). Call this after every
    /// sync or reachability change in HealthSyncManager.
    func publishStatus(lastSyncAt: Date?, serverReachable: Bool) {
        guard WCSession.default.activationState == .activated else { return }
        var ctx: [String: Any] = ["serverReachable": serverReachable]
        if let d = lastSyncAt { ctx["lastSyncAt"] = d.timeIntervalSince1970 }
        try? WCSession.default.updateApplicationContext(ctx)
    }

    // MARK: WCSessionDelegate
    //
    // WatchConnectivity invokes these on a background queue, so they must be
    // `nonisolated`. Each one hops onto the main actor to do anything stateful.

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so we can pair with the next Watch session.
        WCSession.default.activate()
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if message["action"] as? String == "syncNow" {
            Task { @MainActor in
                await HealthSyncManager.shared.syncAll(reason: "watch-nudge")
            }
        }
    }
}
