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
            AppRoot()
                .environmentObject(manager)
                .environmentObject(net)
                .environmentObject(notif)
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

/// First-launch gate. `didOnboard` is the bit that tells us whether the user
/// has been through the three-page intro. Until it flips, the HK access sheet
/// stays sealed — onboarding triggers it itself once the user has been given
/// context. After it flips, ContentView takes over and `.task` re-runs
/// `bootstrap()` (no-op the second time around, see HealthSyncManager).
private struct AppRoot: View {
    @EnvironmentObject var manager: HealthSyncManager
    @EnvironmentObject var notif: NotificationManager
    @AppStorage("didOnboard") private var didOnboard: Bool = false

    var body: some View {
        Group {
            if didOnboard {
                ContentView()
                    .task {
                        await manager.bootstrap()
                        await notif.refreshAuth()
                    }
            } else {
                OnboardingView(done: $didOnboard)
            }
        }
    }
}
