import Foundation
import Combine
@preconcurrency import Pilot

/// Process-global Pilot lifecycle manager. Owns the embedded `Pilot` daemon
/// (one per process) plus the persistent `PilotBinding` to Agent A.
///
/// Public surface: `start()`, `stop()`, `setPeer(...)`, `ensureTrusted(...)`,
/// `send(port:data:)`, `refreshTrust()`. Everything observable is published
/// — Settings + Status read from `PilotBoot.shared` directly.
///
/// A periodic ping task runs on `kind == .pilot` to keep `trustState` and
/// `lastHealthAt` current without waiting for the user to open Settings.
@MainActor
final class PilotBoot: ObservableObject {

    static let shared = PilotBoot()
    private init() {
        // Hydrate everything that's persisted on disk *before* the daemon is
        // up. The Status / Settings UI can then show stale-but-honest values
        // ("you were last connected as X, sent 12 min ago") while the daemon
        // boots in the background.
        if let dict = UserDefaults.standard.dictionary(forKey: PilotBoot.kLocalNodeKey),
           let addr = dict["address"] as? String,
           let nidn = dict["nodeID"] as? NSNumber,
           let pk   = dict["publicKeyPrefix"] as? String {
            self.localNode = LocalNode(address: addr,
                                       nodeID: nidn.uint32Value,
                                       publicKeyPrefix: pk)
        }
        self.lastSuccessfulSendAt = UserDefaults.standard.object(forKey: PilotBoot.kLastSendAtKey) as? Date
        self.lastHealthAt         = UserDefaults.standard.object(forKey: PilotBoot.kLastHealthAtKey) as? Date
        self.lastHandshakeAt      = UserDefaults.standard.object(forKey: PilotBoot.kLastHandshakeAtKey) as? Date
        self.lastTrustCheckAt     = UserDefaults.standard.object(forKey: PilotBoot.kLastTrustCheckAtKey) as? Date
    }

    // Persistence keys — namespaced so they don't collide with UserDefaults
    // entries from elsewhere in the app.
    private static let kLocalNodeKey        = "pilot.localNode"
    private static let kLastSendAtKey       = "pilot.lastSendAt"
    private static let kLastHealthAtKey     = "pilot.lastHealthAt"
    private static let kLastHandshakeAtKey  = "pilot.lastHandshakeAt"
    private static let kLastTrustCheckAtKey = "pilot.lastTrustCheckAt"
    private static let kLastTrustStateKey   = "pilot.lastTrustState"

    // MARK: - Observable state

    @Published private(set) var daemonState: DaemonState = .stopped
    @Published private(set) var trustState:  TrustState  = .noPeer
    @Published private(set) var localNode:   LocalNode?  = nil

    @Published private(set) var peerAddress: String = ""
    @Published private(set) var peerNodeID:  UInt32 = 0

    @Published private(set) var lastError:            String?
    @Published private(set) var lastStartAt:          Date?
    @Published private(set) var lastHandshakeAt:      Date?
    @Published private(set) var lastTrustCheckAt:     Date?
    @Published private(set) var lastSendAt:           Date?   // in-session
    @Published private(set) var lastSuccessfulSendAt: Date?   // persisted
    @Published private(set) var lastHealthAt:         Date?
    @Published private(set) var lastPingOK:           Bool = false

    /// Rolling telemetry on data-exchange sends — latencies (ms), success/fail
    /// counts and byte volume. Persisted in-memory only; cleared on app launch
    /// because the latencies are most useful as a "right now is it healthy?"
    /// signal, not a long-running KPI.
    @Published private(set) var telemetry = PilotTelemetry()

    struct PilotTelemetry: Equatable {
        var sendCount:    Int = 0
        var failCount:    Int = 0
        var bytesSent:    Int = 0
        /// Last N completed sends, in milliseconds, oldest first.
        var recentLatencyMs: [Int] = []
        static let cap = 50

        var p50Ms: Int? { percentile(0.50) }
        var p95Ms: Int? { percentile(0.95) }
        var failRate: Double {
            let total = sendCount + failCount
            return total == 0 ? 0 : Double(failCount) / Double(total)
        }
        private func percentile(_ q: Double) -> Int? {
            guard !recentLatencyMs.isEmpty else { return nil }
            let sorted = recentLatencyMs.sorted()
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.up)) - 1))
            return sorted[idx]
        }
    }

    /// Append a measured send to the telemetry ring buffer + tally success/fail.
    private func recordSendOutcome(latencyMs: Int, bytes: Int, success: Bool) {
        var t = telemetry
        if success {
            t.sendCount += 1
            t.bytesSent += bytes
            t.recentLatencyMs.append(latencyMs)
            if t.recentLatencyMs.count > PilotTelemetry.cap {
                t.recentLatencyMs.removeFirst(t.recentLatencyMs.count - PilotTelemetry.cap)
            }
        } else {
            t.failCount += 1
        }
        telemetry = t
    }

    // MARK: - State enums

    enum DaemonState: String, CustomStringConvertible {
        case stopped, starting, running, failed
        var description: String { rawValue }
    }

    enum TrustState: String, CustomStringConvertible {
        case unknown, handshakeSent, trusted, lost, noPeer
        var description: String { rawValue }
        var canSend: Bool { self == .trusted }
    }

    struct LocalNode: Equatable {
        let address: String
        let nodeID: UInt32
        let publicKeyPrefix: String
    }

    enum PilotBootError: Error, CustomStringConvertible {
        case notReady(String)
        case notConfigured(String)
        case sendFailed(String)
        var description: String {
            switch self {
            case .notReady(let r):       return "Pilot not ready: \(r)"
            case .notConfigured(let r):  return "Pilot not configured: \(r)"
            case .sendFailed(let r):     return "Pilot send failed: \(r)"
            }
        }
    }

    // MARK: - Backing fields

    private var pilot:       Pilot?
    private var binding:     PilotBinding?
    private var pingTask:    Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    /// How often to ping Agent A when we're on the Pilot transport.
    private let pingInterval: TimeInterval = 30

    // MARK: - Lifecycle

    /// Boot the embedded daemon. Idempotent — calling on `.running` is a no-op.
    func start() async {
        switch daemonState {
        case .starting, .running: return
        case .stopped, .failed:   break
        }
        daemonState = .starting
        lastError = nil
        lastStartAt = Date()

        do {
            let dir = dataDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cfg = Pilot.Config(
                dataDir: dir,
                socketPath: "p.sock",
                trustAutoApprove: false,
                keepaliveSeconds: 30
            )
            let p = try Pilot.start(cfg)
            pilot = p
            let node = LocalNode(
                address: p.start.address,
                nodeID: p.start.nodeID,
                publicKeyPrefix: String(p.start.publicKey.prefix(16))
            )
            localNode = node
            // Persist so the UI can show identity on cold start before daemon boots.
            UserDefaults.standard.set([
                "address":         node.address,
                "nodeID":          NSNumber(value: node.nodeID),
                "publicKeyPrefix": node.publicKeyPrefix
            ], forKey: PilotBoot.kLocalNodeKey)
            daemonState = .running
            // Register in the relay directory so the host can resolve this node
            // and deliver trust approvals back to us.
            do {
                try p.setVisibility(isPublic: true)
            } catch {
                // Non-fatal: daemon's running, sends still work to known peers —
                // but the host can't resolve us by address until this succeeds.
                // Surface so Diagnostics can show "directory registration failed".
                lastError = "setVisibility: \(error.localizedDescription)"
            }

            // Re-create binding if peer was already configured (warm boot).
            if !peerAddress.isEmpty, peerNodeID != 0 {
                binding = p.bind(peerNodeID: peerNodeID,
                                 peerAddress: peerAddress,
                                 justification: "HealthSync")
                _ = refreshTrust()
            }
            startPingLoopIfNeeded()
            startReceiveLoopIfNeeded()
        } catch {
            daemonState = .failed
            lastError = "\(error)"
        }
    }

    func stop() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        try? pilot?.stop()
        pilot = nil
        binding = nil
        daemonState = .stopped
        trustState = peerAddress.isEmpty ? .noPeer : .unknown
        localNode = nil
    }

    /// Restart the daemon if iOS reaped us during suspension.
    func ensureRunning() async {
        if daemonState != .running { await start() }
    }

    // MARK: - Peer configuration

    func setPeer(address: String, nodeID: UInt32) {
        peerAddress = address
        peerNodeID  = nodeID
        if address.isEmpty || nodeID == 0 {
            trustState = .noPeer
            binding = nil
            // Forget per-peer cached state — different peer means none of the
            // old timestamps apply.
            UserDefaults.standard.removeObject(forKey: PilotBoot.kLastSendAtKey)
            UserDefaults.standard.removeObject(forKey: PilotBoot.kLastHandshakeAtKey)
            UserDefaults.standard.removeObject(forKey: PilotBoot.kLastTrustCheckAtKey)
            UserDefaults.standard.removeObject(forKey: PilotBoot.kLastTrustStateKey)
            lastSuccessfulSendAt = nil
            lastHandshakeAt      = nil
            lastTrustCheckAt     = nil
            return
        }
        trustState = .unknown
        if let p = pilot {
            binding = p.bind(peerNodeID: nodeID,
                             peerAddress: address,
                             justification: "HealthSync")
        }
    }

    // MARK: - Trust

    @discardableResult
    func ensureTrusted(timeout: TimeInterval = 120) async -> TrustState {
        guard daemonState == .running, let binding = binding else { return trustState }
        do {
            let ok = try await binding.ensureTrusted(timeout: .seconds(Int(timeout)))
            let now = Date()
            lastHandshakeAt = now
            lastTrustCheckAt = now
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastHandshakeAtKey)
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastTrustCheckAtKey)
            trustState = ok ? .trusted : mapTrust(binding.status)
            UserDefaults.standard.set(trustState.rawValue, forKey: PilotBoot.kLastTrustStateKey)
            if ok { lastError = nil }
        } catch {
            lastError = "ensureTrusted: \(error)"
            trustState = mapTrust(binding.status)
        }
        return trustState
    }

    @discardableResult
    func refreshTrust() -> TrustState {
        guard daemonState == .running, let binding = binding else {
            if peerAddress.isEmpty { trustState = .noPeer }
            return trustState
        }
        do {
            let s = try binding.checkTrust()
            trustState = mapTrust(s)
            UserDefaults.standard.set(trustState.rawValue, forKey: PilotBoot.kLastTrustStateKey)
        } catch {
            lastError = "checkTrust: \(error)"
        }
        let now = Date()
        lastTrustCheckAt = now
        UserDefaults.standard.set(now, forKey: PilotBoot.kLastTrustCheckAtKey)
        return trustState
    }

    // MARK: - Send

    /// Send one datagram to the bound peer. Throws if daemon isn't running or
    /// trust isn't established — the OutboxWorker handles backoff + retry.
    func send(port: UInt16, data: Data) async throws {
        guard daemonState == .running else { throw PilotBootError.notReady("daemon \(daemonState)") }
        guard let binding = binding else { throw PilotBootError.notConfigured("no binding") }
        guard trustState.canSend else { throw PilotBootError.notReady("trust \(trustState)") }
        guard data.count <= 60_000 else { throw PilotBootError.sendFailed("payload \(data.count)B exceeds 60KB") }
        do {
            try binding.send(port: port, data: data)
            let now = Date()
            lastSendAt = now
            lastSuccessfulSendAt = now
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastSendAtKey)
        } catch {
            // Trust might have been revoked — refresh so UI reflects reality.
            _ = refreshTrust()
            throw PilotBootError.sendFailed("\(error)")
        }
    }

    /// Send a binary payload to the peer via the dataexchange framing protocol
    /// (stream connection on port 1001, TypeBinary frame). This is what the
    /// managed daemon's dataexchange service expects — it only handles stream
    /// connections, not raw datagrams. Returns the ack string from the server.
    ///
    /// Wire format per `internal/dataexchange`: [4-byte type BE][4-byte len BE][payload]
    @discardableResult
    func sendDataExchange(data: Data, timeout: TimeInterval = 30) async throws -> String {
        guard daemonState == .running, let p = pilot else {
            throw PilotBootError.notReady("daemon \(daemonState)")
        }
        guard trustState.canSend else {
            throw PilotBootError.notReady("trust \(trustState)")
        }
        let addr = peerAddress
        guard !addr.isEmpty else {
            throw PilotBootError.notConfigured("no peer address")
        }

        let frame = Self.makeBinaryFrame(payload: data)
        let started = Date()

        do {
            let ack: String = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let conn = try p.dial(addr: addr, port: 1001,
                                              timeoutMs: UInt64(timeout * 1000))
                        defer { try? conn.close() }
                        _ = try conn.write(frame)
                        let raw = try conn.read(maxBytes: 4096)
                        cont.resume(returning: Self.ackText(from: raw))
                    } catch {
                        cont.resume(throwing: PilotBootError.sendFailed("dataexchange: \(error)"))
                    }
                }
            }
            let now = Date()
            let latency = Int(now.timeIntervalSince(started) * 1000)
            // Server-side error reply ("ERR ...") still counts as a transport
            // failure for telemetry purposes — the bytes left the device but
            // the ack says we shouldn't trust the delivery.
            recordSendOutcome(latencyMs: latency,
                              bytes: frame.count,
                              success: !ack.hasPrefix("ERR"))
            lastSendAt = now
            lastSuccessfulSendAt = now
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastSendAtKey)
            return ack
        } catch {
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            recordSendOutcome(latencyMs: latency,
                              bytes: frame.count,
                              success: false)
            throw error
        }
    }

    /// Dataexchange frame types (mirrors internal/dataexchange constants).
    private enum DXFrameType: UInt32 {
        case text   = 1
        case binary = 2
        case json   = 3
    }

    /// Builds a dataexchange frame: [4-byte type BE][4-byte length BE][payload]
    private static func makeFrame(type: DXFrameType, payload: Data) -> Data {
        var header = Data(count: 8)
        header.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: type.rawValue.bigEndian,         toByteOffset: 0, as: UInt32.self)
            buf.storeBytes(of: UInt32(payload.count).bigEndian, toByteOffset: 4, as: UInt32.self)
        }
        return header + payload
    }

    /// Strips the 8-byte frame header from a received frame and returns the payload as String.
    private static func ackText(from raw: Data) -> String {
        let payload = raw.count > 8 ? raw.dropFirst(8) : raw
        return String(data: payload, encoding: .utf8) ?? "ok"
    }

    private static func makeBinaryFrame(payload: Data) -> Data {
        makeFrame(type: .binary, payload: payload)
    }

    // MARK: - Debug message roundtrip

    /// Port used for debug roundtrip tests — same as the standard dataexchange
    /// port (1001) so no separate echo handler needs to be wired on the peer.
    static let debugPort: UInt16 = 1001

    struct MessageRoundtrip {
        let success: Bool
        let sentBytes: Int
        let replyBytes: Int?
        let replyText: String?
        let replyFrom: String?         // "<addr>:<port>"
        let elapsedMs: Int
        let error: String?
        let sentPayload: String
    }

    /// Send a `pilotctl send-message`-style request to the peer over a Pilot
    /// stream connection and wait for the application-level ack reply.
    ///
    /// This is what `pilotctl send-message <agent> --data '/data {…}'` does
    /// internally: dial the peer on the data-exchange port (1001), write the
    /// request, read the reply. The reply envelope tells you exactly which
    /// layer worked — daemon, trust, transport, *and* the peer-side handler.
    ///
    /// Runs on a background queue: `pilot.dial` / `read` block, and we don't
    /// want to freeze the UI thread waiting for the reply.
    func sendMessageAwaitReply(text: String,
                               port: UInt16 = 1001,
                               timeout: TimeInterval = 30) async -> MessageRoundtrip {
        let data = Data(text.utf8)
        let start = Date()

        // Pre-flight checks — report exactly which layer is missing.
        guard daemonState == .running, let p = pilot else {
            return MessageRoundtrip(
                success: false, sentBytes: data.count, replyBytes: nil,
                replyText: nil, replyFrom: nil,
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000),
                error: "daemon \(daemonState.rawValue)",
                sentPayload: text
            )
        }
        guard trustState.canSend else {
            return MessageRoundtrip(
                success: false, sentBytes: data.count, replyBytes: nil,
                replyText: nil, replyFrom: nil,
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000),
                error: "trust state \(trustState.rawValue)",
                sentPayload: text
            )
        }
        let addr = peerAddress

        // Hop off MainActor — dial/write/read are blocking C calls.
        // Port 1001 is the dataexchange service which expects framed messages.
        // Wrap in a TypeText frame so the server can parse it and echo back an ack.
        let frame = Self.makeFrame(type: .text, payload: data)

        let result: MessageRoundtrip = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let conn = try p.dial(addr: addr, port: port,
                                          timeoutMs: UInt64(timeout * 1000))
                    defer { try? conn.close() }
                    _ = try conn.write(frame)
                    let raw = try conn.read(maxBytes: 65536)
                    let ackText = Self.ackText(from: raw)
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    cont.resume(returning: MessageRoundtrip(
                        success: true,
                        sentBytes: data.count,
                        replyBytes: raw.count > 8 ? raw.count - 8 : raw.count,
                        replyText: ackText,
                        replyFrom: "\(addr):\(port)",
                        elapsedMs: ms,
                        error: nil,
                        sentPayload: text
                    ))
                } catch {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    cont.resume(returning: MessageRoundtrip(
                        success: false,
                        sentBytes: data.count,
                        replyBytes: nil,
                        replyText: nil,
                        replyFrom: nil,
                        elapsedMs: ms,
                        error: "\(error)",
                        sentPayload: text
                    ))
                }
            }
        }

        // Side-effects on success: update last-send timestamps.
        if result.success {
            let now = Date()
            lastSendAt = now
            lastSuccessfulSendAt = now
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastSendAtKey)
        }
        return result
    }

    // MARK: - Receive

    struct Datagram {
        let srcAddr: String
        let srcPort: UInt16
        let dstPort: UInt16
        let data: Data
    }

    /// One-shot receive dispatched to a background queue so it never blocks
    /// the MainActor while waiting for the next inbound datagram.
    func receiveOne() async throws -> Datagram {
        guard let p = pilot else { throw PilotBootError.notReady("daemon stopped") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let dg = try p.receive()
                    cont.resume(returning: Datagram(srcAddr: dg.srcAddr, srcPort: dg.srcPort,
                                                    dstPort: dg.dstPort, data: dg.data))
                } catch {
                    cont.resume(throwing: PilotBootError.sendFailed("receive: \(error)"))
                }
            }
        }
    }

    /// Background loop that drains inbound datagrams. Port 1002 = ack from
    /// the ingest collector; clears the last error on receipt.
    private func startReceiveLoopIfNeeded() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let dg = try await self.receiveOne()
                    if dg.dstPort == 1002 {
                        lastError = nil
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // MARK: - Periodic ping

    /// Periodically probe Agent A: `health()` for daemon liveness, `checkTrust()`
    /// to spot revocations. Idempotent — only one loop runs at a time. Updates
    /// `lastHealthAt`, `lastPingOK`, and `trustState`.
    private func startPingLoopIfNeeded() {
        guard pingTask == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pingOnce()
                try? await Task.sleep(nanoseconds: UInt64((self?.pingInterval ?? 30) * 1_000_000_000))
            }
        }
    }

    /// Fire one ping. Public so Settings can trigger it on-demand.
    ///
    /// Two-stage check:
    ///   1. Local daemon health — fast RPC to the embedded daemon.
    ///   2. Peer echo ping — dials port 7 (PortEcho) on the peer, writes four
    ///      bytes, reads the echo back. This is the same probe `pilotctl ping`
    ///      uses and is the only authoritative signal that the overlay path to
    ///      the peer is up and trusted.
    func pingOnce() async {
        guard daemonState == .running, let p = pilot else {
            lastPingOK = false
            return
        }

        // Stage 1 — local daemon liveness.
        do {
            let h = try p.health()
            guard (h["status"] as? String) == "ok" else {
                lastPingOK = false
                let now = Date()
                lastHealthAt = now
                UserDefaults.standard.set(now, forKey: PilotBoot.kLastHealthAtKey)
                return
            }
        } catch {
            lastPingOK = false
            let now = Date()
            lastHealthAt = now
            UserDefaults.standard.set(now, forKey: PilotBoot.kLastHealthAtKey)
            lastError = "daemon health: \(error)"
            return
        }

        // Stage 2 — peer reachability via port 7 (PortEcho).
        // Skip if no peer is configured (nothing to ping).
        if !peerAddress.isEmpty {
            let addr = peerAddress
            let ok: Bool = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let conn = try p.dial(addr: addr, port: 7, timeoutMs: 5_000)
                        defer { try? conn.close() }
                        _ = try conn.write(Data([0x70, 0x69, 0x6E, 0x67])) // "ping"
                        _ = try conn.read(maxBytes: 64)
                        cont.resume(returning: true)
                    } catch {
                        cont.resume(returning: false)
                    }
                }
            }
            lastPingOK = ok
            if !ok { lastError = "echo ping \(addr):7 failed" }
        } else {
            lastPingOK = true
        }

        let now = Date()
        lastHealthAt = now
        UserDefaults.standard.set(now, forKey: PilotBoot.kLastHealthAtKey)

        if lastPingOK {
            _ = refreshTrust()
            // Retry the handshake if the peer may have approved while we
            // were suspended — catches the case where ensureTrusted() timed
            // out at launch but the approval arrived later.
            if trustState == .handshakeSent || trustState == .unknown {
                _ = await ensureTrusted(timeout: 30)
            }
        }
    }

    // MARK: - Helpers

    func dataDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appendingPathComponent("pilot", isDirectory: true)
    }

    var isReady: Bool {
        daemonState == .running && trustState.canSend
    }

    /// How fresh a ping must be to skip the pre-send re-probe. 60 s = the
    /// periodic ping loop catches drift fast enough that the OutboxWorker
    /// almost never has to pay the extra round-trip itself.
    private let pingFreshness: TimeInterval = 60

    /// Pre-send availability check. Returns true if the daemon is up, trust is
    /// good, AND we've had a successful ping in the last 60s. If the cached
    /// ping is stale or failed, runs a fresh `pingOnce()` synchronously and
    /// returns that result. The OutboxWorker calls this before every send so
    /// we never ship envelopes to a peer we haven't verified is alive.
    func isLikelyAvailable() async -> Bool {
        guard isReady else { return false }
        if let when = lastHealthAt,
           Date().timeIntervalSince(when) < pingFreshness,
           lastPingOK {
            return true
        }
        await pingOnce()
        return lastPingOK && isReady
    }

    var summary: String {
        switch (daemonState, trustState) {
        case (.stopped, _):                        return "Stopped"
        case (.starting, _):                       return "Starting…"
        case (.failed, _):                         return "Failed: \(lastError ?? "unknown")"
        case (.running, .noPeer):                  return "Running · no peer configured"
        case (.running, .unknown):                 return "Running · trust unknown"
        case (.running, .handshakeSent):           return "Running · waiting for peer approval"
        case (.running, .trusted):                 return "Ready"
        case (.running, .lost):                    return "Running · trust lost — re-handshake"
        }
    }

    private func mapTrust(_ s: PilotBinding.TrustStatus) -> TrustState {
        switch s {
        case .unknown:       return peerAddress.isEmpty ? .noPeer : .unknown
        case .handshakeSent: return .handshakeSent
        case .trusted:       return .trusted
        case .lost:          return .lost
        }
    }
}
