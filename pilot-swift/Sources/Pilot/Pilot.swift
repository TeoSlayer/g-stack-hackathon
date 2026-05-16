// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pilot — Swift wrapper around the embedded pilot-daemon C ABI.
//
// Usage:
//
//   let p = try Pilot.start(.init(
//       dataDir: dir, socketPath: "p.sock",
//       trustAutoApprove: true, keepaliveSeconds: 2))
//   try p.handshake(peerID: 12345, justification: "hi")
//   _ = try p.waitForTrust(peerID: 12345, timeoutMs: 30_000)
//   try p.send(to: "0:0000.0000.AAAA", port: 7777, data: Data("hi".utf8))
//   let dg = try p.receive()
//   try p.stop()
//
// One Pilot instance owns one embedded daemon; the C ABI is
// process-global, so create a single Pilot at app launch.
//
// Unix socket sun_path is 104 bytes on darwin/ios. Pass a SHORT
// socketPath — relative paths land inside `dataDir` once Pilot.start
// chdir's there. iOS Application Support paths often exceed the
// limit, so use a basename like "p.sock".

import Foundation
import PilotC

// MARK: - PilotBinding

/// A persistent, self-healing association between this node and a remote peer.
///
/// Create once at app launch via `Pilot.bind(...)`. The binding survives across
/// Pilot restarts as long as the same `dataDir` identity is used. Call
/// `establish()` on first launch (or after a factory reset) to send the
/// handshake; the remote peer approves once, and trust persists from then on.
///
///     let binding = pilot.bind(
///         peerNodeID: 161006,
///         peerAddress: "0:0000.0002.74EE",
///         justification: "HealthSync")
///     try binding.establish()
///     try await binding.waitUntilTrusted()
///     try binding.send(port: 1001, data: envelope)
///
public final class PilotBinding {

    public enum TrustStatus: String, Codable {
        case unknown       // never attempted a handshake
        case handshakeSent // handshake delivered; waiting for peer to approve
        case trusted       // peer is in trustedPeers() — safe to send
        case lost          // was trusted, no longer in trustedPeers()
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notTrusted(TrustStatus)
        case noPilot

        public var description: String {
            switch self {
            case .notTrusted(let s): return "PilotBinding: not trusted (status=\(s.rawValue))"
            case .noPilot:           return "PilotBinding: Pilot instance has been deallocated"
            }
        }
    }

    public let peerNodeID:   UInt32
    public let peerAddress:  String
    public let justification: String

    public private(set) var status: TrustStatus = .unknown

    private weak var pilot: Pilot?

    fileprivate init(pilot: Pilot, peerNodeID: UInt32, peerAddress: String, justification: String) {
        self.pilot         = pilot
        self.peerNodeID    = peerNodeID
        self.peerAddress   = peerAddress
        self.justification = justification
    }

    // MARK: - Trust lifecycle

    /// Send the handshake request to the peer. Idempotent: safe to call again
    /// if the previous attempt timed out or the peer restarted.
    public func establish() throws {
        guard let pilot = pilot else { throw Error.noPilot }
        try pilot.handshake(peerID: peerNodeID, justification: justification)
        status = .handshakeSent
    }

    /// Refresh trust status from the live daemon. Returns the new status.
    ///
    /// Call this at app launch — if this node's `identity.json` and the peer's
    /// `trust.json` entry are both on disk from a previous session, this
    /// returns `.trusted` immediately without any network round-trip.
    @discardableResult
    public func checkTrust() throws -> TrustStatus {
        guard let pilot = pilot else { return status }
        let peers = try pilot.trustedPeers()
        let found = peers.contains {
            ($0["node_id"] as? NSNumber)?.uint32Value == peerNodeID
        }
        if found {
            status = .trusted
        } else if status == .trusted {
            status = .lost
        }
        return status
    }

    /// Block (async) until the peer appears in `trustedPeers()` or `timeout`
    /// elapses. Returns `true` when trusted, `false` on timeout.
    public func waitUntilTrusted(
        timeout: Duration = .seconds(120),
        pollInterval: Duration = .seconds(2)
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let s = try checkTrust()
            if s == .trusted { return true }
            try await Task.sleep(for: pollInterval)
        }
        return false
    }

    /// Ensure the binding is trusted, establishing the handshake if needed.
    ///
    /// Call this once at app launch. On the second and every subsequent launch
    /// `checkTrust()` returns `.trusted` immediately (trust is persisted in
    /// `dataDir/trust.json`), so no network traffic occurs.
    ///
    /// On the very first launch — or after a reinstall that clears
    /// Application Support — this sends the handshake and waits for the peer
    /// to approve. If the peer runs with `trustAutoApprove: true` (Agent A
    /// typically does), this completes in the time it takes for one registry
    /// round-trip (~2–5 s on a good connection).
    ///
    /// Returns `true` when trust is confirmed, `false` if it could not be
    /// established within `timeout`.
    @discardableResult
    public func ensureTrusted(
        timeout: Duration = .seconds(120)
    ) async throws -> Bool {
        // Fast path: already trusted on disk from a previous session.
        if (try? checkTrust()) == .trusted { return true }

        // Slow path: first launch or trust lost — send handshake.
        try establish()
        return try await waitUntilTrusted(timeout: timeout)
    }

    // MARK: - Send

    /// Send a datagram to the bound peer. Throws `.notTrusted` if trust has
    /// not been confirmed yet — call `checkTrust()` or `waitUntilTrusted()`
    /// before the first send, and the send path is reliable thereafter.
    public func send(port: UInt16, data: Data) throws {
        guard status == .trusted else { throw Error.notTrusted(status) }
        guard let pilot = pilot else { throw Error.noPilot }
        try pilot.send(to: peerAddress, port: port, data: data)
    }

    // MARK: - Health

    /// Quick liveness check: is the peer still trusted and the daemon healthy?
    public var isReady: Bool {
        guard let pilot = pilot else { return false }
        guard (try? checkTrust()) == .trusted else { return false }
        guard let h = try? pilot.health(),
              (h["status"] as? String) == "ok" else { return false }
        return true
    }
}

// MARK: - PilotConn

/// A reliable, ordered stream connection to a remote peer.
/// Created by `PilotListener.accept()` (server side) or `Pilot.dial()` (client side).
public final class PilotConn {

    public enum Error: Swift.Error, CustomStringConvertible {
        case readFailed(String)
        case writeFailed(String)
        case closeFailed(String)

        public var description: String {
            switch self {
            case .readFailed(let m):  return "PilotConn read failed: \(m)"
            case .writeFailed(let m): return "PilotConn write failed: \(m)"
            case .closeFailed(let m): return "PilotConn close failed: \(m)"
            }
        }
    }

    private let handle: UInt64
    private var closed = false

    fileprivate init(handle: UInt64) {
        self.handle = handle
    }

    deinit { try? close() }

    /// Read up to `maxBytes` from the stream. Blocks until data arrives.
    public func read(maxBytes: Int = 65536) throws -> Data {
        let ret = PilotConnRead(handle, Int32(maxBytes))
        if let errPtr = ret.r2 {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.readFailed(s)
        }
        guard let ptr = ret.r1 else { return Data() }
        let data = Data(bytes: ptr, count: Int(ret.r0))
        free(ptr)
        return data
    }

    /// Write data to the stream.
    @discardableResult
    public func write(_ data: Data) throws -> Int {
        let ret: PilotConnWrite_return = data.withUnsafeBytes { raw in
            PilotConnWrite(handle,
                          UnsafeMutableRawPointer(mutating: raw.baseAddress),
                          Int32(data.count))
        }
        if let errPtr = ret.r1 {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.writeFailed(s)
        }
        return Int(ret.r0)
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        if let errPtr = PilotConnClose(handle) {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.closeFailed(s)
        }
    }
}

// MARK: - PilotListener

/// A listener bound to a local port. Accepts incoming stream connections from trusted peers.
/// Created by `Pilot.listen(port:)`.
public final class PilotListener {

    public enum Error: Swift.Error, CustomStringConvertible {
        case acceptFailed(String)
        case closeFailed(String)

        public var description: String {
            switch self {
            case .acceptFailed(let m): return "PilotListener accept failed: \(m)"
            case .closeFailed(let m):  return "PilotListener close failed: \(m)"
            }
        }
    }

    private let handle: UInt64
    private var closed = false

    fileprivate init(handle: UInt64) {
        self.handle = handle
    }

    deinit { try? close() }

    /// Block until an incoming connection arrives.
    public func accept() throws -> PilotConn {
        let ret = PilotListenerAccept(handle)
        if let errPtr = ret.r1 {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.acceptFailed(s)
        }
        return PilotConn(handle: UInt64(ret.r0))
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        if let errPtr = PilotListenerClose(handle) {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.closeFailed(s)
        }
    }
}

// MARK: - Pilot

public final class Pilot {

    // MARK: - Public types

    public struct Config {
        public var dataDir: URL
        public var socketPath: String          // relative basename recommended
        public var registryAddr: String        = "34.71.57.205:9000"
        public var beaconAddr: String          = "34.71.57.205:9001"
        public var trustAutoApprove: Bool      = false
        public var keepaliveSeconds: Int       = 30
        public var version: String             = "pilot-swift"

        public init(
            dataDir: URL,
            socketPath: String,
            trustAutoApprove: Bool = false,
            keepaliveSeconds: Int = 30
        ) {
            self.dataDir          = dataDir
            self.socketPath       = socketPath
            self.trustAutoApprove = trustAutoApprove
            self.keepaliveSeconds = keepaliveSeconds
        }
    }

    public struct StartResult {
        public let address: String
        public let nodeID: UInt32
        public let publicKey: String
    }

    public struct Datagram {
        public let srcAddr: String
        public let srcPort: UInt16
        public let dstPort: UInt16
        public let data: Data
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case startFailed(String)
        case rpcFailed(String)
        case invalidResponse(String)

        public var description: String {
            switch self {
            case .startFailed(let m):     return "Pilot start failed: \(m)"
            case .rpcFailed(let m):       return "Pilot RPC failed: \(m)"
            case .invalidResponse(let m): return "Pilot invalid response: \(m)"
            }
        }
    }

    // MARK: - Instance

    public let start: StartResult
    private let driverHandle: UInt64
    private var stopped = false

    private init(start: StartResult, driverHandle: UInt64) {
        self.start = start
        self.driverHandle = driverHandle
    }

    deinit { if !stopped { try? stop() } }

    // MARK: - Lifecycle

    /// Boot the embedded Pilot daemon. Pass a stable `dataDir` inside
    /// Application Support — the daemon writes two files there that must
    /// survive across launches for persistent identity and trust:
    ///
    ///   dataDir/identity.json  — Ed25519 keypair + node_id
    ///                            Generated on first launch; loaded on all
    ///                            subsequent launches. Clearing this means a
    ///                            fresh identity and loss of all peer trust.
    ///
    ///   dataDir/trust.json     — Mutual-trust records with every approved peer.
    ///                            Written whenever a handshake is approved or
    ///                            revoked. On restart, trust is restored from
    ///                            this file — no re-handshake needed.
    ///
    /// Both files are stored inside the app sandbox (Application Support) and
    /// are backed up by iCloud Backup. An iOS uninstall clears them; a
    /// reinstall requires a one-time re-handshake.
    public static func start(_ config: Config) throws -> Pilot {
        try FileManager.default.createDirectory(
            at: config.dataDir, withIntermediateDirectories: true)

        if !config.socketPath.hasPrefix("/") {
            FileManager.default.changeCurrentDirectoryPath(config.dataDir.path)
        }

        let cfgDict: [String: Any] = [
            "data_dir":           config.dataDir.path,
            "socket_path":        config.socketPath,
            "registry_addr":      config.registryAddr,
            "beacon_addr":        config.beaconAddr,
            "trust_auto_approve": config.trustAutoApprove,
            "keepalive_sec":      config.keepaliveSeconds,
            "version":            config.version,
        ]
        let cfgData = try JSONSerialization.data(withJSONObject: cfgDict)
        let cfgStr  = String(data: cfgData, encoding: .utf8) ?? "{}"

        let startResp: [String: Any] = try cfgStr.withCString { cstr in
            try parseJSON(PilotEmbeddedStart(UnsafeMutablePointer(mutating: cstr)))
        }
        if let err = startResp["error"] as? String {
            throw Error.startFailed(err)
        }
        guard
            let address  = startResp["address"]    as? String,
            let nodeID   = (startResp["node_id"]   as? NSNumber)?.uint32Value,
            let pubkey   = startResp["public_key"] as? String
        else {
            throw Error.invalidResponse("start: \(startResp)")
        }
        let result = StartResult(address: address, nodeID: nodeID, publicKey: pubkey)

        let connRet = config.socketPath.withCString { sp in
            PilotConnect(UnsafeMutablePointer(mutating: sp))
        }
        if let errPtr = connRet.r1 {
            let s = String(cString: errPtr)
            FreeString(errPtr)
            throw Error.startFailed("driver connect: \(s)")
        }
        return Pilot(start: result, driverHandle: connRet.r0)
    }

    public func stop() throws {
        guard !stopped else { return }
        stopped = true
        _ = PilotClose(driverHandle)
        let resp = try parseJSON(PilotEmbeddedStop())
        if let err = resp["error"] as? String { throw Error.rpcFailed(err) }
    }

    // MARK: - RPC

    public func info() throws -> [String: Any] {
        try rpc(PilotInfo(driverHandle))
    }

    public func health() throws -> [String: Any] {
        try rpc(PilotHealth(driverHandle))
    }

    public func handshake(peerID: UInt32, justification: String) throws {
        let _ = try justification.withCString { c in
            try rpc(PilotHandshake(driverHandle, peerID, UnsafeMutablePointer(mutating: c)))
        }
    }

    @discardableResult
    public func waitForTrust(peerID: UInt32, timeoutMs: UInt32) throws -> Bool {
        let resp = try rpc(PilotWaitForTrust(driverHandle, peerID, timeoutMs))
        return (resp["trusted"] as? Bool) ?? false
    }

    public func send(to peerAddr: String, port: UInt16, data: Data) throws {
        let fullAddr = "\(peerAddr):\(port)"
        try fullAddr.withCString { addrC in
            try data.withUnsafeBytes { raw in
                let base = UnsafeMutableRawPointer(mutating: raw.baseAddress)
                let ret = PilotSendTo(
                    driverHandle,
                    UnsafeMutablePointer(mutating: addrC),
                    base,
                    Int32(data.count))
                // SendTo returns nil on success, errJSON on failure.
                if let p = ret {
                    let s = String(cString: p)
                    FreeString(p)
                    let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
                    throw Error.rpcFailed(obj?["error"] as? String ?? s)
                }
            }
        }
    }

    public func receive() throws -> Datagram {
        let resp = try rpc(PilotRecvFrom(driverHandle))
        guard
            let src   = resp["src_addr"] as? String,
            let sport = (resp["src_port"] as? NSNumber)?.uint16Value,
            let dport = (resp["dst_port"] as? NSNumber)?.uint16Value
        else {
            throw Error.invalidResponse("recv: \(resp)")
        }
        // Go's encoding/json renders []byte as base64.
        let data: Data
        if let b64 = resp["data"] as? String, let d = Data(base64Encoded: b64) {
            data = d
        } else if let raw = resp["data"] as? [UInt8] {
            data = Data(raw)
        } else {
            data = Data()
        }
        return Datagram(srcAddr: src, srcPort: sport, dstPort: dport, data: data)
    }

    public func trustedPeers() throws -> [[String: Any]] {
        let resp = try rpc(PilotTrustedPeers(driverHandle))
        return (resp["trusted"] as? [[String: Any]]) ?? []
    }

    /// Set whether this node is publicly dialable without prior trust.
    /// When `isPublic = true`, any peer can open a stream connection regardless of trust.
    /// When `isPublic = false` (default), only mutually-trusted peers can connect.
    public func setVisibility(isPublic: Bool) throws {
        _ = try rpc(PilotSetVisibility(driverHandle, isPublic ? 1 : 0))
    }

    // MARK: - Binding

    /// Create a persistent binding to a remote peer. The binding owns the
    /// trust lifecycle (handshake, status polling) and the send path.
    ///
    /// Typical bootstrap at app launch:
    ///
    ///     let binding = pilot.bind(
    ///         peerNodeID: 161006,
    ///         peerAddress: "0:0000.0002.74EE",
    ///         justification: "HealthSync")
    ///
    ///     // First install only — subsequent launches skip this block because
    ///     // trust is already mutual on disk.
    ///     if try binding.checkTrust() != .trusted {
    ///         try binding.establish()
    ///         guard try await binding.waitUntilTrusted() else {
    ///             // Peer hasn't approved yet; show "connecting…" UI and retry.
    ///             return
    ///         }
    ///     }
    ///
    ///     // Trust confirmed — send envelopes.
    ///     try binding.send(port: 1001, data: gzippedEnvelope)
    ///
    public func bind(
        peerNodeID: UInt32,
        peerAddress: String,
        justification: String = "HealthSync"
    ) -> PilotBinding {
        PilotBinding(
            pilot: self,
            peerNodeID: peerNodeID,
            peerAddress: peerAddress,
            justification: justification)
    }

    // MARK: - Stream API (send-message / dataexchange protocol)

    /// Listen for incoming reliable stream connections on `port`.
    ///
    /// To receive messages sent via `pilotctl send-message` (or any peer that dials
    /// via `Pilot.dial`), listen on `PortDataExchange` (1001):
    ///
    ///     let ln = try pilot.listen(port: 1001)
    ///     let conn = try ln.accept()
    ///     let data = try conn.read()
    ///     try conn.close()
    ///     try ln.close()
    ///
    public func listen(port: UInt16) throws -> PilotListener {
        let ret = PilotListen(driverHandle, port)
        if let errPtr = ret.r1 {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.rpcFailed("listen(\(port)): \(s)")
        }
        return PilotListener(handle: UInt64(ret.r0))
    }

    /// Dial a reliable stream connection to `peerAddr:port`.
    ///
    /// Use `PortDataExchange` (1001) to talk to any peer that listens via
    /// `listen(port: 1001)` or via `pilotctl send-message`.
    public func dial(addr: String, port: UInt16, timeoutMs: UInt64 = 30_000) throws -> PilotConn {
        let fullAddr = "\(addr):\(port)"
        let ret: PilotDialTimeout_return = fullAddr.withCString { cstr in
            PilotDialTimeout(driverHandle,
                             UnsafeMutablePointer(mutating: cstr),
                             timeoutMs)
        }
        if let errPtr = ret.r1 {
            let s = String(cString: errPtr); FreeString(errPtr)
            throw Error.rpcFailed("dial(\(fullAddr)): \(s)")
        }
        return PilotConn(handle: UInt64(ret.r0))
    }

    // MARK: - Internal helpers

    private func rpc(_ result: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let resp = try parseJSON(result)
        if let err = resp["error"] as? String { throw Error.rpcFailed(err) }
        return resp
    }
}

/// Decode a freshly-allocated JSON-encoded char* from cgo, free it,
/// and return a [String: Any] dict. Throws Pilot.Error on failures.
fileprivate func parseJSON(_ p: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
    guard let p = p else {
        throw Pilot.Error.invalidResponse("null C return")
    }
    let s = String(cString: p)
    FreeString(p)
    let raw = try JSONSerialization.jsonObject(with: Data(s.utf8))
    guard let dict = raw as? [String: Any] else {
        throw Pilot.Error.invalidResponse("not a JSON object: \(s.prefix(200))")
    }
    return dict
}
