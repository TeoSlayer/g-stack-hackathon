// SPDX-License-Identifier: AGPL-3.0-or-later
//
// pilot-smoke-swift — comprehensive smoke + regression test for the Swift SDK.
//
// Modes:
//   info                        — boot, Info/Health, shut down
//   alice                       — boot (TrustAutoApprove), print ALICE_READY,
//                                 block on receive(), exit on first datagram
//   bob   PEER_ID PEER_ADDR     — boot, PilotBinding trust + send, SMOKE OK
//   async-bind PEER_ID PEER_ADDR— tests PilotBinding.ensureTrusted() (async)
//                                 + isReady + send; expects trust already on disk
//   throughput PEER_ID PEER_ADDR [count]
//                               — trust + send COUNT raw 30 KB datagrams,
//                                 report msgs/sec and MB/sec
//
// Set PILOT_DATA_DIR to use a persistent directory instead of a fresh UUID
// temp dir. This is required for the persistence and fast-path tests.

import Foundation

@discardableResult
func main() -> Int32 {
    let args = CommandLine.arguments

    // Persistent dataDir via env var — required for trust/identity persistence tests.
    let persistDir = ProcessInfo.processInfo.environment["PILOT_DATA_DIR"]
    let dataDir: URL
    if let p = persistDir {
        dataDir = URL(fileURLWithPath: p)
    } else {
        dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilot-swift-\(UUID().uuidString.prefix(8))")
    }

    let mode = args.count >= 2 ? args[1] : "info"

    let cfg = Pilot.Config(
        dataDir: dataDir,
        socketPath: "p.sock",
        trustAutoApprove: (mode == "alice"),
        keepaliveSeconds: 2
    )

    print("BOOT dataDir=\(dataDir.path) mode=\(mode)")

    let pilot: Pilot
    do {
        pilot = try Pilot.start(cfg)
    } catch {
        fputs("FAIL: start: \(error)\n", stderr)
        return 1
    }
    defer { try? pilot.stop() }

    do {
        switch mode {
        case "info":
            return try runInfo(pilot)
        case "alice":
            return try runAlice(pilot)   // optional: test Linux→iOS receive
        case "bob":
            guard args.count >= 4, let peerID = UInt32(args[2]) else {
                fputs("usage: bob PEER_ID PEER_ADDR\n", stderr); return 2
            }
            return try runBob(pilot, peerID: peerID, peerAddr: args[3])
        case "async-bind":
            guard args.count >= 4, let peerID = UInt32(args[2]) else {
                fputs("usage: async-bind PEER_ID PEER_ADDR\n", stderr); return 2
            }
            return try runAsyncBind(pilot, peerID: peerID, peerAddr: args[3])
        case "throughput":
            guard args.count >= 4, let peerID = UInt32(args[2]) else {
                fputs("usage: throughput PEER_ID PEER_ADDR [count]\n", stderr); return 2
            }
            let count = args.count >= 5 ? (Int(args[4]) ?? 50) : 50
            return try runThroughput(pilot, peerID: peerID, peerAddr: args[3], count: count)
        default:
            fputs("unknown mode \(mode); want info|alice|bob|async-bind|throughput\n", stderr)
            return 2
        }
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        return 1
    }
}

// MARK: - info

func runInfo(_ p: Pilot) throws -> Int32 {
    print("INFO node_id=\(p.start.nodeID) addr=\(p.start.address) pubkey=\(p.start.publicKey.prefix(16))…")
    let info = try p.info()
    print("INFO_OK version=\(info["version"] ?? "?") encrypt=\(info["encrypt"] ?? "?")")
    let health = try p.health()
    print("HEALTH_OK status=\(health["status"] ?? "?")")
    print("SMOKE OK")
    return 0
}

// MARK: - alice
// Tests the receive path using the send-message / dataexchange protocol.
//
// Alice sets itself public (no trust required to dial in), then listens on
// port 1001. Host sends via: pilotctl send-message <alice_addr> --data "ping"
// Alice accepts, reads, prints ALICE_RECV + SMOKE OK.
//
// In production the app would be private + mutually trusted. Making it public
// is a shortcut for smoke testing the inbound receive path without the full
// trust handshake ceremony on the host side.

func runAlice(_ p: Pilot) throws -> Int32 {
    try p.setVisibility(isPublic: true)
    print("ALICE_READY node_id=\(p.start.nodeID) addr=\(p.start.address)")

    let ln = try p.listen(port: 1001)
    defer { try? ln.close() }

    let conn = try ln.accept()
    defer { try? conn.close() }
    let data = try conn.read(maxBytes: 65536)
    let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"
    print("ALICE_RECV bytes=\(data.count) data=\"\(body)\"")
    let peers = try p.trustedPeers()
    print("ALICE_PEERS count=\(peers.count)")
    print("SMOKE OK")
    return 0
}

// MARK: - bob

func runBob(_ p: Pilot, peerID: UInt32, peerAddr: String) throws -> Int32 {
    print("BOB_START node_id=\(p.start.nodeID) addr=\(p.start.address) peer_id=\(peerID)")

    let binding = p.bind(peerNodeID: peerID, peerAddress: peerAddr, justification: "pilot-swift-smoke")
    try binding.establish()

    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        if (try? binding.checkTrust()) == .trusted { break }
        Thread.sleep(forTimeInterval: 2)
    }
    print("BOB_TRUST trusted=\(binding.status == .trusted)")
    guard binding.status == .trusted else {
        fputs("FAIL: trust not established within 120s\n", stderr); return 1
    }

    print("BOB_READY isReady=\(binding.isReady)")

    let payload = Data("hi from swift bob (node_id=\(p.start.nodeID) addr=\(p.start.address))".utf8)
    try binding.send(port: 7777, data: payload)
    print("BOB_SENT to=\(peerAddr) port=7777 bytes=\(payload.count)")
    Thread.sleep(forTimeInterval: 2)
    print("SMOKE OK")
    return 0
}

// MARK: - async-bind
// Tests PilotBinding.ensureTrusted() (async path) and isReady.
// Run with PILOT_DATA_DIR pointing at a directory where trust already exists
// to exercise the fast path (returns immediately). Run without it (fresh dir)
// to exercise the slow path (handshake + wait).

func runAsyncBind(_ p: Pilot, peerID: UInt32, peerAddr: String) throws -> Int32 {
    print("ASYNC_BIND_START node_id=\(p.start.nodeID) peer_id=\(peerID)")

    let binding = p.bind(peerNodeID: peerID, peerAddress: peerAddr, justification: "pilot-swift-async-bind")

    // Quick sync check first — if trust is already on disk, we never need the
    // async path and can prove the fast-path works.
    let preStatus = (try? binding.checkTrust()) ?? .unknown
    print("ASYNC_BIND_PRE_STATUS status=\(preStatus.rawValue)")

    var exitCode: Int32 = 0
    let sema = DispatchSemaphore(value: 0)

    Task {
        defer { sema.signal() }
        do {
            let trusted = try await binding.ensureTrusted(timeout: .seconds(120))
            print("ASYNC_BIND_TRUST trusted=\(trusted)")
            print("ASYNC_BIND_READY isReady=\(binding.isReady)")
            if trusted {
                let payload = Data("async-bind ping from node_id=\(p.start.nodeID)".utf8)
                try binding.send(port: 7777, data: payload)
                print("ASYNC_BIND_SENT bytes=\(payload.count)")
                print("SMOKE OK")
            } else {
                fputs("FAIL: ensureTrusted returned false\n", stderr)
                exitCode = 1
            }
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exitCode = 1
        }
    }

    sema.wait()
    Thread.sleep(forTimeInterval: 2)
    return exitCode
}

// MARK: - throughput
// Sends COUNT raw 30 KB datagrams to PEER_ADDR:1001.
// No ACK wait — measures raw outbound send rate from iOS.
// Verify delivery count on the peer with `pilotctl info` traffic delta.

func runThroughput(_ p: Pilot, peerID: UInt32, peerAddr: String, count: Int) throws -> Int32 {
    print("THROUGHPUT_START node_id=\(p.start.nodeID) peer_id=\(peerID) count=\(count)")

    let binding = p.bind(peerNodeID: peerID, peerAddress: peerAddr, justification: "pilot-throughput")

    // Establish trust (fast path if already on disk, slow path on first run).
    if (try? binding.checkTrust()) != .trusted {
        try binding.establish()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if (try? binding.checkTrust()) == .trusted { break }
            Thread.sleep(forTimeInterval: 2)
        }
    }
    guard binding.status == .trusted else {
        fputs("FAIL: trust not established\n", stderr); return 1
    }
    print("THROUGHPUT_TRUSTED")

    // ~30 KB payload with repetitive content (matches gzip-compressed HK envelope size).
    // The pattern is compressible so the content resembles a real gzipped JSON body.
    var payloadBytes = [UInt8](repeating: 0, count: 30_000)
    let pattern: [UInt8] = Array("{\"kind\":\"quantity\",\"value\":72.0}".utf8)
    for i in 0..<payloadBytes.count { payloadBytes[i] = pattern[i % pattern.count] }
    let payload = Data(payloadBytes)

    let start = Date()
    var sent = 0
    var failed = 0

    for i in 0..<count {
        do {
            try binding.send(port: 1001, data: payload)
            sent += 1
        } catch {
            failed += 1
            fputs("send \(i) failed: \(error)\n", stderr)
        }
        if (i + 1) % 10 == 0 {
            let elapsed = Date().timeIntervalSince(start)
            let rate = elapsed > 0 ? Double(sent) / elapsed : 0
            print("  t=\(Int(elapsed))s msgs=\(sent) \(String(format: "%.1f", rate)) msg/s")
        }
    }

    let elapsed = Date().timeIntervalSince(start)
    let totalBytes = Int64(sent) * Int64(payload.count)
    let rate = elapsed > 0 ? Double(sent) / elapsed : 0
    let mbps = elapsed > 0 ? Double(totalBytes) / elapsed / 1_000_000 : 0

    print("THROUGHPUT_DONE")
    print("  sent=\(sent)/\(count) failed=\(failed)")
    print("  elapsed=\(String(format: "%.1f", elapsed))s")
    print("  rate=\(String(format: "%.1f", rate)) msg/s | \(String(format: "%.0f", rate*60)) msg/min")
    print("  throughput=\(String(format: "%.2f", mbps)) MB/s")
    Thread.sleep(forTimeInterval: 3)
    print("SMOKE OK")
    return 0
}

exit(main())
