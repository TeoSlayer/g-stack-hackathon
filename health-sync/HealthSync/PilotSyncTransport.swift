import Foundation

/// Pilot-overlay transport. Builds an envelope, compresses with zlib, then
/// delivers via the dataexchange framing protocol: stream connection on port
/// 1001, TypeBinary frame (4-byte type + 4-byte length + payload). The managed
/// daemon's dataexchange service stores each frame as a BINARY inbox message and
/// acks with "ACK BINARY N bytes". Raw datagrams are NOT handled by that service.
struct PilotSyncTransport: SyncTransport {
    let kind: TransportKind = .pilot
    let deviceID: String
    let peerAddress: String
    let peerNodeID: UInt32

    /// Dial the peer's echo port (7) via `PilotBoot.pingOnce`, then surface
    /// the result. Returning `isReady` alone — the previous behaviour — said
    /// nothing about whether the peer was actually reachable, so the
    /// "Ping peer" button looked broken (no state change after a tap).
    func ping() async -> Bool {
        await PilotBoot.shared.pingOnce()
        return await MainActor.run { PilotBoot.shared.lastPingOK && PilotBoot.shared.isReady }
    }

    func ingest(samples: [[String: Any]], metadata: [String: Any]?) async throws -> IngestResult {
        // Always verify the peer is alive before sending. PilotBoot caches the
        // last successful ping for 60 s, so this is free in the common case.
        let available = await PilotBoot.shared.isLikelyAvailable()
        guard available else {
            let summary = await MainActor.run { PilotBoot.shared.summary }
            throw SyncError.transport("pilot: \(summary)")
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let batchID = UUID().uuidString
        let envelope: [String: Any] = [
            "v":           1,
            "source":      "ios.healthsync",
            "device_id":   deviceID,
            "app_version": appVersion,
            "batch_id":    batchID,
            "sent_at":     Date().timeIntervalSince1970,
            "encoding":    "deflate",
            "samples":     samples,
            "metadata":    metadata ?? [:],
        ]

        // Encode + compress off main — same pattern as HTTPSyncTransport.
        let payload: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard JSONSerialization.isValidJSONObject(envelope) else {
                    let reason = describeInvalidJSON(envelope) ?? "unknown"
                    cont.resume(throwing: SyncError.encodingFailed(reason)); return
                }
                do {
                    let json = try JSONSerialization.data(withJSONObject: envelope)
                    let compressed = try (json as NSData).compressed(using: .zlib) as Data
                    cont.resume(returning: compressed)
                } catch {
                    cont.resume(throwing: SyncError.encodingFailed("\(error)"))
                }
            }
        }

        // Use the dataexchange framing protocol (stream on port 1001).
        // The managed daemon's dataexchange service only handles stream
        // connections — raw datagrams (binding.send) are silently dropped.
        do {
            let ack = try await PilotBoot.shared.sendDataExchange(data: payload)
            // Ack text from server: "ACK BINARY N bytes" on success, "ERR ..." on failure.
            if ack.hasPrefix("ERR") {
                throw SyncError.transport("pilot: \(ack)")
            }
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.transport("\(error)")
        }

        // The server's ack confirms the batch was written to disk — real
        // accepted count comes from the ack; for now we trust sample count.
        return IngestResult(
            accepted: samples.count,
            duplicate: 0,
            rejected: 0
        )
    }
}
