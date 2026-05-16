import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var manager: HealthSyncManager
    /// Hard cap so a fresh install with no HK data ever doesn't sit on the
    /// splash forever — set to true after 6 s regardless of readiness.
    @State private var splashTimedOut = false

    var body: some View {
        ZStack {
            TabView {
                NavigationStack { StatusTab() }
                    .tabItem { Label("Status", systemImage: "heart.text.square") }

                NavigationStack { TrendsView() }
                    .tabItem { Label("Trends", systemImage: "chart.line.uptrend.xyaxis") }

                NavigationStack { ModelsView() }
                    .tabItem { Label("Models", systemImage: "function") }

                NavigationStack { SettingsTab() }
                    .tabItem { Label("Settings", systemImage: "gear") }
            }
            if showSplash {
                SplashView()
                    .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.35), value: showSplash)
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            splashTimedOut = true
        }
    }

    /// Splash stays up until either Readiness has been calibrated OR ~6 s have
    /// passed (so a fresh install with no HK data doesn't get stuck forever).
    private var showSplash: Bool {
        if splashTimedOut { return false }
        if manager.readiness.band != .unknown { return false }
        if !manager.recentSyncs.isEmpty { return false }
        return true
    }
}

// MARK: Status

private struct StatusTab: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared

    var body: some View {
        List {
            Section {
                if manager.readiness.band == .unknown && manager.isWorking {
                    LoadingHero(title: "Readiness", subtitle: manager.currentActivity)
                } else {
                    ReadinessHero(reading: manager.readiness)
                }
            }
            if let warn = worstWarning {
                Section("Watch out for") {
                    NavigationLink {
                        ModelsView()
                    } label: {
                        WarningRow(reading: warn)
                    }
                }
            } else if manager.modelReadings.isEmpty && manager.isWorking {
                Section("Insights") {
                    LoadingRow(text: "Computing models…")
                }
            }
            Section {
                StatusHero()
            }
            Section("Last 24h activity") {
                if manager.recentSyncs.isEmpty && manager.isWorking {
                    LoadingRow(text: "Waiting for first sync…")
                } else {
                    ActivityChart(events: manager.recentSyncs)
                        .frame(height: 160)
                    TotalsRow(events: manager.recentSyncs)
                }
            }
            Section {
                NavigationLink("Activity & sync controls") {
                    ActivityAndControlsView()
                }
            }
        }
        .navigationTitle("HealthSync")
        .refreshable {
            await manager.pingServer()
            await manager.syncAll(reason: "pull-to-refresh")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await manager.pingServer()
                        await manager.syncAll(reason: "force")
                    }
                } label: {
                    if manager.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .imageScale(.large)
                    }
                }
                .disabled(manager.isWorking || !canForceSync)
                .accessibilityLabel("Force sync now")
            }
        }
    }

    /// Force-sync gate: HTTP always allowed; Pilot needs daemon + trust ready.
    private var canForceSync: Bool {
        switch manager.transportKind {
        case .http:  return true
        case .pilot: return manager.pilotConfigured && PilotBoot.shared.isReady
        }
    }

    /// Pick the single most-urgent non-green model to surface inline. .bad outranks .warn.
    private var worstWarning: ModelReading? {
        manager.modelReadings
            .filter { $0.band == .bad || $0.band == .warn }
            .sorted { ($0.band == .bad ? 0 : 1) < ($1.band == .bad ? 0 : 1) }
            .first
    }
}

private struct LoadingHero: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct LoadingRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct WarningRow: View {
    let reading: ModelReading
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: reading.band == .bad ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(reading.band == .bad ? .red : .orange)
                Text(reading.title).font(.subheadline.bold())
                Spacer()
                Text(reading.valueText).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(reading.action)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct ActivityAndControlsView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject private var pilot = PilotBoot.shared
    @State private var confirmDeepBackfill = false
    var body: some View {
        List {
            Section {
                Button {
                    Task { await manager.syncAll(reason: "manual") }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.clockwise")
                        Spacer()
                        if manager.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(manager.isWorking || !canSync)
                Button {
                    confirmDeepBackfill = true
                } label: {
                    Label("Full backfill…", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(manager.isWorking || !canSync)
                Button {
                    Task { await manager.pingServer(userInitiated: true) }
                } label: {
                    Label("Ping \(pingTargetName)", systemImage: "wave.3.right")
                }
                .disabled(!canPing)
                if !canSync {
                    Text(syncBlockedReason)
                        .font(.footnote).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Sync (\(manager.transportKind.displayName))")
            } footer: {
                Text("**Sync now** ships only samples newer than the per-type anchor. **Full backfill** resets all anchors and re-walks the last \(HealthSyncManager.backfillWindowDays) days — useful after a reinstall or a server rebuild.")
                    .font(.caption2)
            }
            .confirmationDialog("Reset anchors and re-walk \(HealthSyncManager.backfillWindowDays) days?",
                                isPresented: $confirmDeepBackfill,
                                titleVisibility: .visible) {
                Button("Re-walk \(HealthSyncManager.backfillWindowDays) days") {
                    Task {
                        await manager.syncAll(reason: "manual-backfill",
                                              backfillDays: HealthSyncManager.backfillWindowDays,
                                              resetAnchors: true)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every per-type anchor will be wiped and the last \(HealthSyncManager.backfillWindowDays) days of HealthKit data re-sent. Expect a few minutes of heavy network use.")
            }
            Section("Recent events") {
                if manager.recentSyncs.isEmpty && manager.isWorking {
                    LoadingRow(text: "Waiting for first event…")
                } else if manager.recentSyncs.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(manager.recentSyncs.prefix(20)) { ev in
                        ActivityRow(event: ev)
                    }
                    if manager.recentSyncs.count > 20 {
                        NavigationLink("Full log (\(manager.recentSyncs.count))") {
                            SyncHistoryView(history: manager.recentSyncs)
                        }
                    }
                }
            }
            Section("Health data") {
                LabeledContent("HealthKit", value: manager.authorizationStatus)
            }
            Section {
                BackgroundRunRow()
            } header: {
                Text("Background refresh")
            } footer: {
                Text("iOS decides when to wake HealthSync in the background — typically every 1–6 h depending on usage. If this hasn't run for a day, check **Settings → General → Background App Refresh**.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pingTargetName: String {
        switch manager.transportKind {
        case .http:  return "server"
        case .pilot: return manager.pilotConfigured ? "peer" : "(no peer)"
        }
    }
    private var canPing: Bool {
        switch manager.transportKind {
        case .http:  return true
        case .pilot: return manager.pilotConfigured && pilot.daemonState == .running
        }
    }
    private var canSync: Bool {
        switch manager.transportKind {
        case .http:  return true
        case .pilot: return manager.pilotConfigured && pilot.isReady
        }
    }
    private var syncBlockedReason: String {
        if manager.transportKind != .pilot { return "" }
        if !manager.pilotConfigured        { return "Add a remote node in Settings → Transport → Pilot before syncing." }
        if pilot.daemonState != .running   { return "Pilot daemon isn't running. Restart it from Settings." }
        if !pilot.trustState.canSend       { return "Pilot trust not established. Open Settings → Pilot → Establish trust, then have the homelab run `pilotctl approve`." }
        return ""
    }
}

/// One-line row showing when iOS last woke the app in the background and
/// whether the sync that ran inside that window succeeded. The OS won't tell
/// the user this themselves so it's a frequent source of "is this thing
/// even running?" support questions — keep it on-screen.
private struct BackgroundRunRow: View {
    @EnvironmentObject var manager: HealthSyncManager
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                if let when = manager.lastBackgroundRunAt {
                    Text("Last wake-up")
                    Spacer()
                    Text(when, style: .relative)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not woken yet by iOS")
                    Spacer()
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            if manager.lastBackgroundRunAt != nil {
                Text("\(manager.lastBackgroundRunKind) · \(manager.lastBackgroundRunResult)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color)
            }
        }
        .padding(.vertical, 2)
    }
    private var icon: String {
        guard let when = manager.lastBackgroundRunAt else { return "moon.zzz" }
        return Date().timeIntervalSince(when) < 6 * 3600 ? "checkmark.circle.fill"
                                                         : "clock.badge.exclamationmark"
    }
    private var color: Color {
        guard let when = manager.lastBackgroundRunAt else { return .secondary }
        if manager.lastBackgroundRunResult == "expired" { return .orange }
        return Date().timeIntervalSince(when) < 6 * 3600 ? .green : .orange
    }
}

/// Big "Readiness" number + one-sentence advice. The whole point of the app.
private struct ReadinessHero: View {
    let reading: ReadinessReading
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if reading.band == .unknown {
                    Text("—")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(reading.score)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(color)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Readiness").font(.subheadline.bold())
                        InfoButton(info: InfoContent.readiness)
                    }
                    Text(bandLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(reading.advice)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let t = reading.todayHRV, let b = reading.baselineHRV {
                Text(String(format: "Overnight HRV %.0f ms · 7-day baseline %.0f ms (%.0f%%)",
                            t, b, (reading.percentOfBaseline ?? 0) * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch reading.band {
        case .recovered: return .green
        case .moderate:  return .yellow
        case .depleted:  return .red
        case .unknown:   return .secondary
        }
    }
    private var bandLabel: String {
        switch reading.band {
        case .recovered: return "RECOVERED"
        case .moderate:  return "MODERATE"
        case .depleted:  return "DEPLETED"
        case .unknown:   return "CALIBRATING"
        }
    }
}

/// Compact, transport-specific footer shown under the Status hero when the
/// Pilot transport is active. Quick glance: trust state, last ping, last send.
private struct PilotStatusStrip: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var pilot = PilotBoot.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !manager.pilotConfigured {
                Label("No remote node — Settings → Transport → Pilot",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    trustChip
                    Spacer()
                    if let when = pilot.lastHealthAt {
                        Image(systemName: pilot.lastPingOK ? "checkmark.circle" : "xmark.circle")
                        Text("pinged")
                        // `Text(date, style: .relative)` is iOS's self-updating
                        // relative-time view — refreshes on its own once a second
                        // and outputs "0s ago" cleanly instead of "in 0 seconds".
                        Text(when, style: .relative).monospacedDigit()
                    } else {
                        Label("never pinged", systemImage: "questionmark.circle")
                    }
                }
                .font(.caption)
                .foregroundColor(pilot.lastHealthAt == nil
                                 ? .secondary
                                 : (pilot.lastPingOK ? .secondary : .orange))
                if let sent = pilot.lastSuccessfulSendAt {
                    HStack(spacing: 4) {
                        Text("Last envelope shipped")
                        Text(sent, style: .relative).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var trustChip: some View {
        let (label, color): (String, Color) = {
            switch pilot.trustState {
            case .trusted:       return ("trusted",            .green)
            case .handshakeSent: return ("handshake pending",  .yellow)
            case .lost:          return ("trust lost",         .red)
            case .unknown:       return ("trust unknown",      .orange)
            case .noPeer:        return ("no peer",            .secondary)
            }
        }()
        Label(label, systemImage: pilot.trustState == .trusted
              ? "lock.shield.fill" : "lock.open.fill")
            .foregroundStyle(color)
    }
}

private struct ActivityRow: View {
    let event: HealthSyncManager.SyncEvent
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.date.formatted(.dateTime.hour().minute().second()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(event.message)
                .font(.footnote)
                .foregroundColor(event.success ? .primary : .red)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

private struct StatusHero: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var pilot = PilotBoot.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 12, height: 12)
                Text(stateText).font(.headline)
                Spacer()
                if manager.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                if manager.isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(manager.currentActivity)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            if let last = manager.lastSyncDate {
                Text("Last sync \(Self.relative(last)) — \(manager.lastSyncResult)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Label(net.connection.rawValue, systemImage: netIcon)
                Spacer()
                transportBadge
            }
            .font(.subheadline)
            if manager.transportKind == .pilot {
                PilotStatusStrip()
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    /// Compact transport indicator. HTTP → cloud icon + reachable state.
    /// Pilot → antenna icon + daemon/trust state.
    @ViewBuilder
    private var transportBadge: some View {
        switch manager.transportKind {
        case .http:
            Label(manager.serverReachable ? "server up" : "server down",
                  systemImage: manager.serverReachable ? "checkmark.icloud" : "icloud.slash")
                .foregroundStyle(manager.serverReachable ? .green : .secondary)
        case .pilot:
            Label(pilot.summary,
                  systemImage: pilot.isReady
                    ? "antenna.radiowaves.left.and.right"
                    : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(pilot.isReady ? .green : .orange)
                .lineLimit(1)
        }
    }

    private var stateColor: Color {
        if manager.transportKind == .pilot {
            if !manager.pilotConfigured        { return .orange }
            if pilot.daemonState != .running   { return .red }
            if !pilot.trustState.canSend       { return .orange }
            if let d = manager.lastSyncDate,
               Date().timeIntervalSince(d) < 15 * 60 { return .green }
            return .yellow
        }
        if !manager.serverReachable { return .orange }
        if let d = manager.lastSyncDate, Date().timeIntervalSince(d) < 15 * 60 { return .green }
        return .yellow
    }
    private var stateText: String {
        if manager.transportKind == .pilot {
            if !manager.pilotConfigured        { return "Paused — add a remote node" }
            if pilot.daemonState != .running   { return "Paused — Pilot daemon down" }
            if !pilot.trustState.canSend       { return "Paused — peer trust pending" }
        } else if !manager.serverReachable {
            return "Paused — server unreachable"
        }
        if manager.lastSyncDate == nil { return "Awaiting first sync" }
        return "Syncing"
    }
    private var netIcon: String {
        switch net.connection {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .offline: return "wifi.slash"
        default: return "questionmark"
        }
    }
    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

fileprivate func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: Settings

private struct SettingsTab: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject private var pilot = PilotBoot.shared
    @State private var draftURL: String = ""
    @State private var editing = false
    @State private var draftPilotAddr: String = ""
    @State private var draftPilotID:   String = ""
    @State private var editingPilot = false

    var body: some View {
        Form {
            Section("Transport") {
                Picker("Sync over", selection: Binding(
                    get: { manager.transportKind },
                    set: { manager.updateTransport($0) }
                )) {
                    Label(TransportKind.http.displayName, systemImage: TransportKind.http.symbol)
                        .tag(TransportKind.http)
                    Label(TransportKind.pilot.displayName, systemImage: TransportKind.pilot.symbol)
                        .tag(TransportKind.pilot)
                }
                if manager.transportKind == .pilot && !manager.pilotConfigured {
                    Label("Pilot is unavailable — add a remote node below.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            if manager.transportKind == .http {
                Section("Server (HTTP)") {
                    if editing {
                        TextField("http://192.168.5.66:8100", text: $draftURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        HStack {
                            Button("Cancel") { editing = false }
                            Spacer()
                            Button("Save") {
                                manager.updateServerURL(draftURL.trimmingCharacters(in: .whitespacesAndNewlines))
                                editing = false
                            }
                            .disabled(URL(string: draftURL) == nil)
                        }
                    } else {
                        LabeledContent("URL", value: manager.serverURL)
                        Button("Edit URL") {
                            draftURL = manager.serverURL
                            editing = true
                        }
                    }
                }
            } else {
                Section("Pilot daemon") {
                    HStack {
                        Image(systemName: pilot.isReady ? "checkmark.circle.fill"
                                                        : "exclamationmark.triangle.fill")
                            .foregroundStyle(pilot.isReady ? .green : .orange)
                        Text(pilot.summary).font(.subheadline.bold())
                    }
                    if let node = pilot.localNode {
                        LabeledContent("This device addr", value: node.address)
                        LabeledContent("This device id",   value: "\(node.nodeID)")
                        LabeledContent("Public key",       value: node.publicKeyPrefix + "…")
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("Daemon not running — local identity unavailable.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Last ping") {
                        if let when = pilot.lastHealthAt {
                            Text(when, style: .relative).monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Last ping result",
                        value: pilot.lastPingOK ? "ok" : "—")
                    HStack {
                        Button("Restart") {
                            Task {
                                PilotBoot.shared.stop()
                                await PilotBoot.shared.start()
                            }
                        }
                        Spacer()
                        Button("Ping now") {
                            Task { await PilotBoot.shared.pingOnce() }
                        }
                        Spacer()
                        Button("Refresh trust") {
                            _ = PilotBoot.shared.refreshTrust()
                        }
                        .disabled(!manager.pilotConfigured)
                    }
                    .buttonStyle(.bordered)
                    if let err = pilot.lastError {
                        Text("Last error: \(err)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                Section("Remote node") {
                    if editingPilot {
                        TextField("0:0000.0002.74EE", text: $draftPilotAddr)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospacedDigit())
                        Text("Format: `N:HHHH.HHHH.HHHH` — one colon after the network number, dots (not colons) between hex groups. From `pilotctl info` on the homelab.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Live preview of what will actually be saved — catches
                        // colon-vs-dot mistakes before the user hits Save.
                        let preview = HealthSyncManager.normalizePilotAddress(draftPilotAddr)
                        if !draftPilotAddr.isEmpty && preview != draftPilotAddr {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("Will save as: \(preview)").font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(.orange)
                        }
                        TextField("node id (e.g. 161006)", text: $draftPilotID)
                            .keyboardType(.numberPad)
                        HStack {
                            Button("Cancel") {
                                editingPilot = false
                                draftPilotAddr = ""
                                draftPilotID = ""
                            }
                            Spacer()
                            Button(manager.pilotConfigured ? "Save changes" : "Add remote") {
                                let addr = draftPilotAddr.trimmingCharacters(in: .whitespacesAndNewlines)
                                let id   = UInt32(draftPilotID) ?? 0
                                manager.updatePilotPeer(address: addr, nodeID: id)
                                editingPilot = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(draftPilotAddr.isEmpty || UInt32(draftPilotID) == nil)
                        }
                    } else if manager.pilotConfigured {
                        LabeledContent("Address", value: manager.pilotPeerAddress)
                            .font(.body.monospacedDigit())
                        LabeledContent("Node id", value: "\(manager.pilotPeerNodeID)")
                        LabeledContent("Trust",   value: pilot.trustState.rawValue)
                        HStack {
                            Button("Edit") {
                                draftPilotAddr = manager.pilotPeerAddress
                                draftPilotID = "\(manager.pilotPeerNodeID)"
                                editingPilot = true
                            }
                            Spacer()
                            Button("Establish trust") {
                                Task { _ = await PilotBoot.shared.ensureTrusted() }
                            }
                            .disabled(pilot.daemonState != .running || pilot.trustState == .trusted)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                manager.clearPilotPeer()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No remote node configured",
                                  systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(.subheadline.bold())
                            Text("Run `pilotctl info` on your homelab, copy the address + node id, then add them here. Until you do, Pilot transport is unavailable and HealthSync will refuse to send over Pilot.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                draftPilotAddr = ""
                                draftPilotID = ""
                                editingPilot = true
                            } label: {
                                Label("Add remote", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Identity") {
                LabeledContent("Device ID", value: manager.deviceID)
            }
            Section("About") {
                LabeledContent("Version",
                  value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Build",
                  value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
            }
            Section("Explore") {
                NavigationLink {
                    LocationMapView()
                } label: {
                    Label("Location heatmap", systemImage: "map")
                }
            }
            Section("Troubleshooting") {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: Sync history

private struct SyncHistoryView: View {
    let history: [HealthSyncManager.SyncEvent]
    var body: some View {
        List(history) { ev in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ev.kind.capitalized).font(.subheadline.bold())
                    Spacer()
                    Text(ev.date.formatted(.dateTime.hour().minute().second()))
                        .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                }
                Text(ev.message)
                    .font(.footnote)
                    .foregroundColor(ev.success ? .secondary : .red)
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Activity chart (Swift Charts)

/// Samples-accepted per hour over the last 24h, stacked by HealthKit type.
/// Reads directly from the in-memory ring buffer — no extra plumbing.
/// Last-24h sync activity as a stacked-bar chart per hour. Restricted to the
/// top-5 types by total volume + an "Other" bucket so one giant type doesn't
/// crush everything else into the baseline; Y-axis tick formatter uses
/// human-readable abbreviations (1k / 10k / 1M) instead of scientific notation.
private struct ActivityChart: View {
    let events: [HealthSyncManager.SyncEvent]
    private let topN = 5

    var body: some View {
        let buckets = bucketed
        if buckets.isEmpty {
            Text("No syncs in the last 24 hours yet.")
                .foregroundStyle(.secondary).font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Chart(buckets) { row in
                BarMark(
                    x: .value("Hour", row.hour, unit: .hour),
                    y: .value("Samples", row.accepted)
                )
                .foregroundStyle(by: .value("Type", row.typeId))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let n = value.as(Int.self) {
                            Text(Self.abbrev(n))
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 4)
        }
    }

    private struct Bucket: Identifiable {
        let id = UUID()
        let hour: Date
        let typeId: String
        let accepted: Int
    }

    /// Group sample-accepted events into per-hour buckets. Anything outside
    /// the top-N types collapses into a single "Other" series so the legend
    /// stays readable and a single dominant type doesn't flatten everything.
    private var bucketed: [Bucket] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let cal = Calendar.current

        // First pass: total per type to pick the top-N.
        var typeTotals: [String: Int] = [:]
        for ev in events where ev.kind == "sync" && ev.success {
            guard let t = ev.typeId, let n = ev.accepted, n > 0, ev.date >= cutoff else { continue }
            typeTotals[t, default: 0] += n
        }
        let topTypes = Set(typeTotals.sorted { $0.value > $1.value }
                                    .prefix(topN)
                                    .map(\.key))

        // Second pass: bucket by hour, collapsing non-top types into "Other".
        var sums: [String: [Date: Int]] = [:]
        for ev in events where ev.kind == "sync" && ev.success {
            guard let t = ev.typeId, let n = ev.accepted, n > 0, ev.date >= cutoff else { continue }
            let label = topTypes.contains(t) ? t : "Other"
            let hour = cal.dateInterval(of: .hour, for: ev.date)?.start ?? ev.date
            sums[label, default: [:]][hour, default: 0] += n
        }
        return sums.flatMap { typeId, hours in
            hours.map { Bucket(hour: $0.key, typeId: typeId, accepted: $0.value) }
        }
        .sorted { $0.hour < $1.hour }
    }

    /// Human-readable abbreviator for axis labels. 942000 → "942k", 1.2M → "1.2M".
    static func abbrev(_ n: Int) -> String {
        let a = abs(n)
        switch a {
        case ..<1_000:      return "\(n)"
        case ..<10_000:     return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000:  return "\(n / 1_000)k"
        case ..<10_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default:            return "\(n / 1_000_000)M"
        }
    }
}

/// Top-N type totals over the last 24h shown as a horizontal pill row.
private struct TotalsRow: View {
    let events: [HealthSyncManager.SyncEvent]
    var body: some View {
        let totals = topTotals
        if totals.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(totals, id: \.0) { type, count in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                            // Use the same abbreviator as the chart so a 942k
                            // pill doesn't render as ambiguous "942.107" (which
                            // depends on locale and confuses thousands vs dots).
                            Text(ActivityChart.abbrev(count))
                                .font(.callout.monospacedDigit().bold())
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var topTotals: [(String, Int)] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var sums: [String: Int] = [:]
        for ev in events where ev.kind == "sync" && ev.success && ev.date >= cutoff {
            if let t = ev.typeId, let n = ev.accepted, n > 0 { sums[t, default: 0] += n }
        }
        return sums.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
    }
}
