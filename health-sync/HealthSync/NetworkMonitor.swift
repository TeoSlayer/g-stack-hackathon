import Foundation
import Network
import Combine
import os

private let log = Logger(subsystem: "io.vulturelabs.healthsync", category: "network")

/// Wraps `NWPathMonitor` for SwiftUI. Tracks live network status so the
/// diagnostics view and the sync engine can both react.
@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    enum Connection: String { case wifi, cellular, wired, loopback, unknown, offline }

    @Published var connection: Connection = .unknown
    @Published var isExpensive: Bool = false
    @Published var isConstrained: Bool = false
    @Published var supportsIPv4: Bool = false
    @Published var supportsIPv6: Bool = false
    /// SSID lookup requires Wi-Fi entitlement which Personal Team can't grant.
    /// We expose this property so the UI can show "—" if entitlement is missing.
    @Published var wifiSSID: String? = nil

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.vulturelabs.healthsync.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let conn: Connection = {
                if path.status != .satisfied { return .offline }
                if path.usesInterfaceType(.wifi)         { return .wifi }
                if path.usesInterfaceType(.cellular)     { return .cellular }
                if path.usesInterfaceType(.wiredEthernet){ return .wired }
                if path.usesInterfaceType(.loopback)     { return .loopback }
                return .unknown
            }()
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let v4 = path.supportsIPv4
            let v6 = path.supportsIPv6
            Task { @MainActor in
                guard let self else { return }
                self.connection    = conn
                self.isExpensive   = expensive
                self.isConstrained = constrained
                self.supportsIPv4  = v4
                self.supportsIPv6  = v6
            }
            log.info("network: \(conn.rawValue) expensive=\(expensive) constrained=\(constrained)")
        }
        monitor.start(queue: queue)
    }

    var summary: String {
        var bits: [String] = [connection.rawValue]
        if isExpensive   { bits.append("expensive") }
        if isConstrained { bits.append("constrained") }
        if !supportsIPv4 && !supportsIPv6 { bits.append("no-ip") }
        return bits.joined(separator: ", ")
    }
}
