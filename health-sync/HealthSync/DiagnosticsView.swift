import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var notif = NotificationManager.shared

    @State private var running = false
    @State private var dnsResult: Diagnostics.DNSResult?
    @State private var tcpResult: Diagnostics.TCPResult?
    @State private var httpResult: Diagnostics.HTTPResult?
    @State private var hkRows: [(type: String, status: String)] = []

    var body: some View {
        List {
            networkSection
            serverSection
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
        out.append("device:  \(manager.deviceID)")
        out.append("server:  \(manager.serverURL)")
        out.append("net:     \(net.summary)")
        if let r = dnsResult  { out.append("dns:     \(r.summary)") }
        if let r = tcpResult  { out.append("tcp:     \(r.summary)") }
        if let r = httpResult { out.append("http:    \(r.summary)") }
        out.append("notif:   \(notif.authState.rawValue) alerts=\(notif.alertsEnabled)")
        out.append("hk:")
        for r in hkRows { out.append("  \(r.type): \(r.status)") }
        return out.joined(separator: "\n")
    }
}

