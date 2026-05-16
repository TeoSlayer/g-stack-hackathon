import Foundation
import UserNotifications
import os

private let log = Logger(subsystem: "io.vulturelabs.healthsync", category: "notif")

/// Light wrapper around UNUserNotificationCenter.
///
/// What we notify on:
/// - Sync goes unhealthy after being healthy (stale > N min)
/// - Sync recovers
/// - Manual "test notification" button from the diagnostics view
///
/// We deliberately do NOT spam on every sync — just transitions.
@MainActor
final class NotificationManager: ObservableObject {

    static let shared = NotificationManager()

    enum AuthState: String { case unknown, denied, granted, provisional }

    @Published var authState: AuthState = .unknown
    @Published var alertsEnabled: Bool = UserDefaults.standard.bool(forKey: "notifAlertsEnabled")

    private var lastWasHealthy: Bool? = nil
    private let healthyThreshold: TimeInterval = 15 * 60  // older than 15 min = unhealthy

    func refreshAuth() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authState = Self.map(settings.authorizationStatus)
    }

    func requestAuth() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            authState = granted ? .granted : .denied
        } catch {
            log.warning("notif auth request failed: \(error.localizedDescription)")
            authState = .denied
        }
    }

    func setAlertsEnabled(_ on: Bool) {
        alertsEnabled = on
        UserDefaults.standard.set(on, forKey: "notifAlertsEnabled")
    }

    /// Called by HealthSyncManager whenever sync state changes meaningfully.
    func evaluateSyncHealth(lastSuccess: Date?, serverReachable: Bool) async {
        guard alertsEnabled, authState == .granted else { return }
        let isHealthy: Bool = {
            if !serverReachable { return false }
            guard let last = lastSuccess else { return false }
            return Date().timeIntervalSince(last) < healthyThreshold
        }()
        defer { lastWasHealthy = isHealthy }
        guard let prev = lastWasHealthy, prev != isHealthy else { return }
        if isHealthy {
            await fire(title: "HealthSync recovered",
                       body: "Synced again. Last upload \(Self.fmtRelative(lastSuccess)).")
        } else {
            await fire(title: "HealthSync paused",
                       body: serverReachable
                            ? "No new health data in the last \(Int(healthyThreshold/60)) min."
                            : "Server unreachable — health data is queued locally.")
        }
    }

    /// Fire a one-line alert when readiness drops *into* the depleted band
    /// from a healthier one. We intentionally don't notify on every recompute
    /// or on lateral moves (moderate→moderate). The rate-limit gate avoids
    /// hammering the user when a flapping HRV value bounces around the
    /// moderate/depleted threshold.
    private var lastReadinessNotificationAt: Date?
    private let readinessNotifyMinInterval: TimeInterval = 6 * 3600  // 6h

    func evaluateReadiness(previous: ReadinessReading.Band,
                           current:  ReadinessReading) async {
        guard alertsEnabled, authState == .granted else { return }
        guard previous != .unknown, previous != .depleted,
              current.band == .depleted else { return }
        if let last = lastReadinessNotificationAt,
           Date().timeIntervalSince(last) < readinessNotifyMinInterval {
            return
        }
        lastReadinessNotificationAt = Date()
        let body: String = {
            if let pct = current.percentOfBaseline {
                return "Overnight HRV \(Int(pct * 100))% of your 7-day baseline. \(current.advice)"
            }
            return current.advice
        }()
        await fire(title: "Readiness dropped — take it easy", body: body)
    }

    func test() async {
        await fire(title: "HealthSync test", body: "Notifications are working.")
    }

    /// Fire a notification if alerts are enabled & granted. Used by ad-hoc
    /// signals like the "wear your watch" reminder.
    func notify(title: String, body: String) async {
        guard alertsEnabled, authState == .granted else { return }
        await fire(title: title, body: body)
    }

    private func fire(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do { try await UNUserNotificationCenter.current().add(req) }
        catch { log.warning("notify failed: \(error.localizedDescription)") }
    }

    private static func map(_ s: UNAuthorizationStatus) -> AuthState {
        switch s {
        case .authorized:    return .granted
        case .provisional:   return .provisional
        case .denied:        return .denied
        case .notDetermined: return .unknown
        case .ephemeral:     return .granted
        @unknown default:    return .unknown
        }
    }

    private static func fmtRelative(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
