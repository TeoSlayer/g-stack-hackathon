import SwiftUI
import HealthKit
import BackgroundTasks
import UserNotifications
import os

@main
struct HealthSyncApp: App {
    @StateObject private var manager = HealthSyncManager.shared
    @StateObject private var net = NetworkMonitor.shared
    @StateObject private var notif = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register BG tasks before the app finishes launching.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: HealthSyncManager.bgRefreshIdentifier,
            using: nil
        ) { task in
            HealthSyncManager.shared.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: HealthSyncManager.bgProcessingIdentifier,
            using: nil
        ) { task in
            HealthSyncManager.shared.handleBackgroundProcessing(task as! BGProcessingTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .environmentObject(net)
                .environmentObject(notif)
                .task {
                    await manager.bootstrap()
                    await notif.refreshAuth()
                }
                // iOS can reap the embedded Pilot daemon while the app is
                // suspended. On foreground entry, restart it (no-op if already
                // running) so the next sync doesn't silently fail at the
                // transport layer.
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await PilotBoot.shared.ensureRunning() }
                    }
                }
        }
    }
}
