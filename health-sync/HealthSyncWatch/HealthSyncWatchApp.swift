import SwiftUI

@main
struct HealthSyncWatchApp: App {
    @StateObject private var manager = WatchHealthManager.shared
    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(manager)
                .task { await manager.bootstrap() }
        }
    }
}
