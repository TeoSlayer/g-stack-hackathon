import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var manager: HealthSyncManager

    var body: some View {
        ZStack {
            TabView {
                NavigationStack { StatusTab() }
                    .tabItem { Label("Status", systemImage: "heart.text.square") }

                NavigationStack { CalendarView() }
                    .tabItem { Label("Calendar", systemImage: "calendar") }

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
    }

    /// Splash stays up until either Readiness has been calibrated OR ~6 s have
    /// passed (so a fresh install with no HK data doesn't get stuck forever).
    private var showSplash: Bool {
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
    var body: some View {
        List {
            Section("Sync") {
                Button {
                    Task { await manager.syncAll(reason: "manual") }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.clockwise")
                        Spacer()
                        if manager.isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(manager.isWorking)
                Button {
                    Task { await manager.pingServer() }
                } label: { Label("Ping server", systemImage: "wave.3.right") }
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
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
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
                Label(manager.serverReachable ? "server up" : "server down",
                      systemImage: manager.serverReachable ? "checkmark.icloud" : "icloud.slash")
                    .foregroundStyle(manager.serverReachable ? .green : .secondary)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        if !manager.serverReachable { return .orange }
        if let d = manager.lastSyncDate, Date().timeIntervalSince(d) < 15 * 60 { return .green }
        return .yellow
    }
    private var stateText: String {
        if !manager.serverReachable { return "Paused — server unreachable" }
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

// MARK: Settings

private struct SettingsTab: View {
    @EnvironmentObject var manager: HealthSyncManager
    @State private var draftURL: String = ""
    @State private var editing = false

    var body: some View {
        Form {
            Section("Server") {
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
            Section("Wake window") {
                Stepper(value: Binding(
                    get: { manager.wakeStartHour },
                    set: { manager.updateWakeWindow(start: $0, end: manager.wakeEndHour) }
                ), in: 0...23) {
                    LabeledContent("Start", value: String(format: "%02d:00", manager.wakeStartHour))
                }
                Stepper(value: Binding(
                    get: { manager.wakeEndHour },
                    set: { manager.updateWakeWindow(start: manager.wakeStartHour, end: $0) }
                ), in: 0...23) {
                    LabeledContent("End", value: String(format: "%02d:00", manager.wakeEndHour))
                }
                Text("Behavioural reminders (e.g. \"wear your watch\") only fire during this window.")
                    .font(.footnote).foregroundStyle(.secondary)
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
private struct ActivityChart: View {
    let events: [HealthSyncManager.SyncEvent]
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
                AxisMarks(values: .stride(by: .hour, count: 4)) { v in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
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

    /// Group sample-accepted events into per-hour, per-type bars over the last 24h.
    private var bucketed: [Bucket] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let cal = Calendar.current
        var sums: [String: [Date: Int]] = [:]  // typeId → hour → accepted
        for ev in events where ev.kind == "sync" && ev.success {
            guard let typeId = ev.typeId, let accepted = ev.accepted,
                  accepted > 0, ev.date >= cutoff else { continue }
            let hour = cal.dateInterval(of: .hour, for: ev.date)?.start ?? ev.date
            sums[typeId, default: [:]][hour, default: 0] += accepted
        }
        return sums.flatMap { typeId, hours in
            hours.map { Bucket(hour: $0.key, typeId: typeId, accepted: $0.value) }
        }
        .sorted { $0.hour < $1.hour }
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
                            Text("\(count)").font(.callout.monospacedDigit().bold())
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
