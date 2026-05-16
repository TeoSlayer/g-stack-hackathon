import Foundation
import Network
import HealthKit
import os

private let log = Logger(subsystem: "io.vulturelabs.healthsync", category: "diag")

/// Single-fire latch so two concurrent NWConnection callbacks (or the
/// callback racing the timeout) only resume the continuation once.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// One-shot diagnostic probes. Each method returns a typed result so the
/// SwiftUI view can render it nicely AND a text summary can be assembled.
struct Diagnostics {

    struct DNSResult {
        let host: String
        let resolved: [String]
        let error: String?
        let elapsedMs: Int
        var ok: Bool { error == nil && !resolved.isEmpty }
        var summary: String {
            if let e = error { return "DNS FAIL — \(e) (\(elapsedMs) ms)" }
            return "DNS ok — \(resolved.joined(separator: ", ")) (\(elapsedMs) ms)"
        }
    }

    struct TCPResult {
        let host: String
        let port: Int
        let connected: Bool
        let error: String?
        let elapsedMs: Int
        var summary: String {
            connected ? "TCP \(host):\(port) ok (\(elapsedMs) ms)"
                      : "TCP \(host):\(port) FAIL — \(error ?? "?") (\(elapsedMs) ms)"
        }
    }

    struct HTTPResult {
        let url: String
        let status: Int?
        let elapsedMs: Int
        let error: String?
        var ok: Bool { (status ?? 0) >= 200 && (status ?? 0) < 300 }
        var summary: String {
            if let e = error { return "HTTP \(url) FAIL — \(e)" }
            return "HTTP \(url) → \(status ?? -1) (\(elapsedMs) ms)"
        }
    }

    /// Resolve a host via NWEndpoint. Surfaces actual POSIX-style error text
    /// when resolution fails (e.g. "8 nodename nor servname provided").
    static func resolveDNS(_ host: String) async -> DNSResult {
        let start = Date()
        let latch = Latch()
        guard !host.isEmpty, host != "?", let port = NWEndpoint.Port(rawValue: 80) else {
            return DNSResult(host: host, resolved: [], error: "invalid host", elapsedMs: 0)
        }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: port,
                using: .tcp
            )
            conn.stateUpdateHandler = { state in
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                switch state {
                case .ready:
                    guard latch.tryFire() else { return }
                    var resolved: [String] = []
                    if let remote = conn.currentPath?.remoteEndpoint, case let .hostPort(host: h, port: _) = remote {
                        resolved.append("\(h)")
                    }
                    conn.cancel()
                    cont.resume(returning: DNSResult(host: host, resolved: resolved, error: nil, elapsedMs: elapsed))
                case .failed(let err):
                    guard latch.tryFire() else { return }
                    conn.cancel()
                    cont.resume(returning: DNSResult(host: host, resolved: [], error: "\(err)", elapsedMs: elapsed))
                case .waiting(let err):
                    guard latch.tryFire() else { return }
                    conn.cancel()
                    cont.resume(returning: DNSResult(host: host, resolved: [], error: "\(err)", elapsedMs: elapsed))
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                guard latch.tryFire() else { return }
                conn.cancel()
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                cont.resume(returning: DNSResult(host: host, resolved: [], error: "timeout", elapsedMs: elapsed))
            }
        }
    }

    /// Open a TCP connection and immediately close it — proves L4 reachability.
    static func tcpProbe(host: String, port: Int) async -> TCPResult {
        let start = Date()
        let latch = Latch()
        guard !host.isEmpty, host != "?",
              port > 0, port <= 65535,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return TCPResult(host: host, port: port, connected: false, error: "invalid host/port", elapsedMs: 0)
        }
        return await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: nwPort,
                using: .tcp
            )
            conn.stateUpdateHandler = { state in
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                switch state {
                case .ready:
                    guard latch.tryFire() else { return }
                    conn.cancel()
                    cont.resume(returning: TCPResult(host: host, port: port, connected: true, error: nil, elapsedMs: elapsed))
                case .failed(let err), .waiting(let err):
                    guard latch.tryFire() else { return }
                    conn.cancel()
                    cont.resume(returning: TCPResult(host: host, port: port, connected: false, error: "\(err)", elapsedMs: elapsed))
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                guard latch.tryFire() else { return }
                conn.cancel()
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                cont.resume(returning: TCPResult(host: host, port: port, connected: false, error: "timeout", elapsedMs: elapsed))
            }
        }
    }

    static func httpProbe(urlString: String, path: String = "/healthz") async -> HTTPResult {
        let url = URL(string: urlString + path)
        let start = Date()
        guard let url else {
            return HTTPResult(url: urlString + path, status: nil, elapsedMs: 0, error: "bad URL")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        let s = URLSession(configuration: cfg)
        do {
            let (_, resp) = try await s.data(from: url)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode
            return HTTPResult(url: url.absoluteString, status: code, elapsedMs: elapsed, error: nil)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return HTTPResult(url: url.absoluteString, status: nil, elapsedMs: elapsed, error: error.localizedDescription)
        }
    }

    /// Probes each HK type by running a tiny read query (limit 1). iOS returns
    /// `.sharingDenied` for read-only types whenever the auth dialog has been
    /// dismissed, regardless of the user's actual choice — so the auth-status
    /// API is a privacy lie. The only honest answer is "did a read succeed?".
    /// "readable" = at least one sample came back. "0 samples" is ambiguous
    /// (denied OR genuinely empty store). "error" is a real read failure.
    static func healthKitProbe() async -> [(type: String, status: String)] {
        guard HKHealthStore.isHealthDataAvailable() else {
            return [("HealthKit", "not available on this device")]
        }
        let store = HKHealthStore()
        var rows: [(String, String)] = []
        for id in HKTypes.quantityIdentifiers {
            guard let t = HKObjectType.quantityType(forIdentifier: id) else { continue }
            let label = t.identifier.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            rows.append((label, await readProbe(type: t, store: store)))
        }
        for id in HKTypes.categoryIdentifiers {
            guard let t = HKObjectType.categoryType(forIdentifier: id) else { continue }
            let label = t.identifier.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            rows.append((label, await readProbe(type: t, store: store)))
        }
        rows.append(("Workout", await readProbe(type: HKObjectType.workoutType(), store: store)))
        return rows
    }

    /// Runs `HKSampleQuery` with limit 1. Returns "readable" if any sample is
    /// returned (proves read permission), "0 samples" if none (ambiguous), or
    /// the error message on failure.
    private static func readProbe(type: HKSampleType, store: HKHealthStore) async -> String {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: nil) { _, samples, err in
                if let err = err { cont.resume(returning: "error: \(err.localizedDescription)"); return }
                cont.resume(returning: (samples?.isEmpty == false) ? "readable" : "0 samples")
            }
            store.execute(q)
        }
    }
}
