import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var notif = NotificationManager.shared
    @ObservedObject var pilot = PilotBoot.shared

    @State private var running = false
    @State private var dnsResult: Diagnostics.DNSResult?
    @State private var tcpResult: Diagnostics.TCPResult?
    @State private var httpResult: Diagnostics.HTTPResult?
    @State private var hkRows: [(type: String, status: String)] = []
    /// Millisecond latency of the last fresh pilot ping, captured in `runAll()`.
    @State private var pilotPingMs: Int?
    @State private var testMessage: String = "hello from HealthSync"
    @State private var testPortText: String = "1001"
    @State private var lastRoundtrip: PilotBoot.MessageRoundtrip?
    @State private var sendInFlight = false

    var body: some View {
        List {
            networkSection
            transportSection
            if manager.transportKind == .http {
                serverSection
            } else {
                pilotSection
            }
            healthKitSection
            notificationsSection
            reportSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await runAll() } } label: {
                    if running { ProgressView() } else { Image(systemName: "stethoscope") }
                }
                .disabled(running)
            }
        }
        .task { await runAll() }
    }

    // MARK: sections

    private var networkSection: some View {
        Section("Network") {
            row("Connection", net.connection.rawValue, ok: net.connection != .offline)
            row("Wi-Fi expensive", net.isExpensive ? "yes" : "no", ok: !net.isExpensive)
            row("Constrained", net.isConstrained ? "yes" : "no", ok: !net.isConstrained)
            row("IPv4", net.supportsIPv4 ? "yes" : "no", ok: net.supportsIPv4)
            row("IPv6", net.supportsIPv6 ? "yes" : "no", ok: net.supportsIPv6)
            if let ssid = net.wifiSSID { row("SSID", ssid, ok: true) }
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            row("Active", manager.transportKind.displayName, ok: true)
            row("Reachable", manager.serverReachable ? "yes" : "no",
                ok: manager.serverReachable)
            if let d = manager.lastSyncDate {
                row("Last sync", d.formatted(.dateTime.hour().minute()), ok: true)
            } else {
                row("Last sync", "—", ok: false)
            }
            row("Events recorded",
                "\(manager.recentSyncs.count) (cap \(manager.recentSyncs.prefix(200).count))",
                ok: true)
        }
    }

    private var serverSection: some View {
        Section("Server (\(host))") {
            row("URL", manager.serverURL, ok: true)
            if let dns = dnsResult {
                row("DNS", dns.summary, ok: dns.ok)
            }
            if let tcp = tcpResult {
                row("TCP \(port)", tcp.summary, ok: tcp.connected)
            }
            if let http = httpResult {
                row("HTTP /healthz", http.summary, ok: http.ok)
            }
            Button("Re-run") { Task { await runAll() } }
                .disabled(running)
        }
    }

    @ViewBuilder
    private var pilotSection: some View {
        Section("Pilot (\(pilot.daemonState.rawValue))") {
            row("Summary", pilot.summary, ok: pilot.isReady)
            if let node = pilot.localNode {
                row("My address", node.address, ok: true)
                row("My node id", "\(node.nodeID)", ok: true)
                row("Public key", node.publicKeyPrefix + "…", ok: true)
            } else {
                row("Identity", "not loaded", ok: false)
            }
            row("Peer address",
                manager.pilotPeerAddress.isEmpty ? "—" : manager.pilotPeerAddress,
                ok: manager.pilotConfigured)
            row("Peer node id",
                manager.pilotPeerNodeID == 0 ? "—" : "\(manager.pilotPeerNodeID)",
                ok: manager.pilotConfigured)
            row("Trust", pilot.trustState.rawValue, ok: pilot.trustState.canSend)
            row("Last ping",
                pilot.lastHealthAt.map { Self.fmt($0) } ?? "—",
                ok: pilot.lastPingOK)
            row("Last ping result",
                pilot.lastPingOK ? "ok" : (pilot.lastHealthAt == nil ? "—" : "fail"),
                ok: pilot.lastPingOK)
            if let ms = pilotPingMs {
                row("Last ping latency", "\(ms) ms", ok: ms < 2000)
            }
            row("Last successful send",
                pilot.lastSuccessfulSendAt.map { Self.fmt($0) } ?? "—",
                ok: pilot.lastSuccessfulSendAt != nil)
            row("Last handshake",
                pilot.lastHandshakeAt.map { Self.fmt($0) } ?? "—",
                ok: pilot.lastHandshakeAt != nil)
            row("Last trust check",
                pilot.lastTrustCheckAt.map { Self.fmt($0) } ?? "—",
                ok: pilot.lastTrustCheckAt != nil)
            if let err = pilot.lastError {
                row("Last error", err, ok: false)
            }
            HStack {
                Button("Ping now") {
                    Task { await runPilotPing() }
                }
                Spacer()
                Button("Refresh trust") {
                    _ = PilotBoot.shared.refreshTrust()
                }
                .disabled(!manager.pilotConfigured)
                Spacer()
                Button("Establish trust") {
                    Task { _ = await PilotBoot.shared.ensureTrusted() }
                }
                .disabled(!manager.pilotConfigured || pilot.daemonState != .running
                          || pilot.trustState == .trusted)
            }
            .buttonStyle(.bordered)
            Button("Restart daemon") {
                Task {
                    PilotBoot.shared.stop()
                    await PilotBoot.shared.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        Section("Message roundtrip") {
            Text("Sends a message to the peer and waits up to 5 s for a reply. Send-success alone proves trust + transport are working (peer's daemon decrypted and accepted the datagram). A reply also proves a peer-side handler is listening on the chosen port and echoing back.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Message").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                TextField("hello from HealthSync", text: $testMessage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HStack {
                Text("Port").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                TextField("1001", text: $testPortText).keyboardType(.numberPad)
            }
            Button {
                Task {
                    sendInFlight = true
                    defer { sendInFlight = false }
                    let port = UInt16(testPortText) ?? PilotBoot.debugPort
                    lastRoundtrip = await PilotBoot.shared.sendMessageAwaitReply(
                        text: testMessage, port: port, timeout: 5)
                }
            } label: {
                HStack {
                    Label("Send & wait for reply", systemImage: "paperplane.fill")
                    Spacer()
                    if sendInFlight { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(sendInFlight
                      || testMessage.isEmpty
                      || UInt16(testPortText) == nil
                      || !pilot.isReady)
            if let r = lastRoundtrip {
                roundtripResultRow(r)
            }
        }
    }

    @ViewBuilder
    private func roundtripResultRow(_ r: PilotBoot.MessageRoundtrip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: resultIcon(r))
                    .foregroundStyle(resultTint(r))
                Text(resultHeadline(r))
                    .font(.subheadline.bold())
                Spacer()
                Text("\(r.elapsedMs) ms · \(r.sentBytes) B")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let err = r.error {
                Text(err)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(r.success ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let from = r.replyFrom {
                Text("← from \(from)").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let txt = r.replyText {
                Text(txt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            } else if r.replyBytes != nil {
                Text("\(r.replyBytes!) B (non-UTF8 payload)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("sent: \(r.sentPayload)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    private func resultIcon(_ r: PilotBoot.MessageRoundtrip) -> String {
        if !r.success { return "xmark.octagon.fill" }
        if r.replyText != nil || r.replyBytes != nil { return "checkmark.seal.fill" }
        return "paperplane.circle.fill"
    }
    private func resultTint(_ r: PilotBoot.MessageRoundtrip) -> Color {
        if !r.success { return .red }
        if r.replyText != nil || r.replyBytes != nil { return .green }
        return .orange
    }
    private func resultHeadline(_ r: PilotBoot.MessageRoundtrip) -> String {
        if !r.success { return "Send failed" }
        if r.replyText != nil || r.replyBytes != nil { return "Reply received" }
        return "Sent — no reply yet"
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private var healthKitSection: some View {
        Section("HealthKit auth") {
            if hkRows.isEmpty {
                Text("Probing…").foregroundStyle(.secondary).font(.footnote)
            } else {
                ForEach(hkRows, id: \.type) { r in
                    row(r.type, r.status, ok: r.status == "readable")
                }
                Text("iOS hides real read-permission state for privacy. \"readable\" proves a sample came back; \"0 samples\" means either denied or genuinely empty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            row("Permission", notif.authState.rawValue, ok: notif.authState == .granted)
            Toggle("Alert on sync issues", isOn: Binding(
                get: { notif.alertsEnabled },
                set: { notif.setAlertsEnabled($0) }
            ))
            if notif.authState != .granted {
                Button("Request permission") {
                    Task { await notif.requestAuth() }
                }
            }
            Button("Send test notification") {
                Task { await notif.test() }
            }.disabled(notif.authState != .granted)
        }
    }

    private var reportSection: some View {
        Section("Report") {
            Text(textReport())
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            Button("Copy") {
                UIPasteboard.general.string = textReport()
            }
        }
    }

    // MARK: helpers

    private var host: String {
        URL(string: manager.serverURL)?.host ?? "?"
    }
    private var port: Int {
        URL(string: manager.serverURL)?.port ?? 8100
    }

    private func runAll() async {
        running = true
        defer { running = false }
        let h = host
        let p = port
        let url = manager.serverURL

        // Run probes sequentially — they're cheap (parallel adds little) and
        // sequential makes failures clearer. Each probe is wrapped so any
        // single failure doesn't take down the whole view.
        dnsResult  = await Diagnostics.resolveDNS(h)
        tcpResult  = await Diagnostics.tcpProbe(host: h, port: p)
        httpResult = await Diagnostics.httpProbe(urlString: url)
        hkRows     = await Diagnostics.healthKitProbe()
        await notif.refreshAuth()
        // Always exercise Pilot too, regardless of which transport is active —
        // diagnostics is about *what's possible*, not just what's currently
        // selected.
        await runPilotPing()
    }

    /// Run one fresh pilot ping and capture round-trip latency.
    private func runPilotPing() async {
        let start = Date()
        await PilotBoot.shared.pingOnce()
        pilotPingMs = Int(Date().timeIntervalSince(start) * 1000)
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundColor(ok ? .primary : .red)
                .font(.subheadline.monospacedDigit())
        }
    }

    private func textReport() -> String {
        var out: [String] = []
        out.append("HealthSync diagnostic report — \(Date().formatted())")
        out.append("device:        \(manager.deviceID)")
        out.append("transport:     \(manager.transportKind.rawValue)")
        out.append("server URL:    \(manager.serverURL)")
        out.append("net:           \(net.summary)")
        out.append("reachable:     \(manager.serverReachable)")
        if let d = manager.lastSyncDate {
            out.append("last sync:     \(d.formatted())")
        }
        out.append("events recorded: \(manager.recentSyncs.count)")
        out.append("")
        out.append("# Server (HTTP)")
        if let r = dnsResult  { out.append("  dns:   \(r.summary)") }
        if let r = tcpResult  { out.append("  tcp:   \(r.summary)") }
        if let r = httpResult { out.append("  http:  \(r.summary)") }
        out.append("")
        out.append("# Pilot")
        out.append("  daemon state:     \(pilot.daemonState.rawValue)")
        out.append("  trust state:      \(pilot.trustState.rawValue)")
        out.append("  ready:            \(pilot.isReady)")
        if let n = pilot.localNode {
            out.append("  my address:       \(n.address)")
            out.append("  my node id:       \(n.nodeID)")
            out.append("  my pubkey prefix: \(n.publicKeyPrefix)")
        }
        out.append("  peer address:     \(manager.pilotPeerAddress.isEmpty ? "—" : manager.pilotPeerAddress)")
        out.append("  peer node id:     \(manager.pilotPeerNodeID == 0 ? "—" : "\(manager.pilotPeerNodeID)")")
        out.append("  last ping:        \(pilot.lastHealthAt.map { "\($0)" } ?? "—")")
        out.append("  last ping ok:     \(pilot.lastPingOK)")
        if let ms = pilotPingMs       { out.append("  last ping latency: \(ms) ms") }
        if let d = pilot.lastSuccessfulSendAt { out.append("  last send ok:     \(d)") }
        if let d = pilot.lastHandshakeAt      { out.append("  last handshake:   \(d)") }
        if let d = pilot.lastTrustCheckAt     { out.append("  last trust check: \(d)") }
        if let e = pilot.lastError            { out.append("  last error:       \(e)") }
        out.append("")
        out.append("# Notifications")
        out.append("  permission: \(notif.authState.rawValue)")
        out.append("  alerts:     \(notif.alertsEnabled)")
        out.append("")
        out.append("# HealthKit")
        for r in hkRows { out.append("  \(r.type): \(r.status)") }
        return out.joined(separator: "\n")
    }
}

