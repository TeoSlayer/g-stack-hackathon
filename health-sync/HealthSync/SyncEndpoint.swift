import Foundation

/// HTTP transport: POSTs sample envelopes to the existing pod's `/ingest`,
/// pings `/healthz` for reachability. Source-of-truth implementation today;
/// kept working in parallel with the Pilot stub so the manager can flip
/// between them without code changes.
struct HTTPSyncTransport: SyncTransport {
    let kind: TransportKind = .http
    let baseURL: String
    let deviceID: String

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg)
    }()

    func ping() async -> Bool {
        guard let url = URL(string: "\(baseURL)/healthz") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func ingest(samples: [[String: Any]], metadata: [String: Any]?) async throws -> IngestResult {
        guard let url = URL(string: "\(baseURL)/ingest") else { throw SyncError.badURL }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let deviceID = self.deviceID
        let meta = metadata ?? [:]
        // JSON encoding off the main actor — for 200-sample chunks this is
        // ~100 KB of work that would block UI if left inline. `isValidJSONObject`
        // is a defensive pre-check so we throw cleanly instead of letting
        // JSONSerialization raise an unrecoverable NSException on bad inputs.
        let data: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let body: [String: Any] = [
                    "device_id":   deviceID,
                    "app_version": appVersion,
                    "samples":     samples,
                    "metadata":    meta,
                ]
                guard JSONSerialization.isValidJSONObject(body) else {
                    let reason = describeInvalidJSON(body) ?? "unknown"
                    cont.resume(throwing: SyncError.encodingFailed(reason)); return
                }
                do {
                    let d = try JSONSerialization.data(withJSONObject: body)
                    cont.resume(returning: d)
                } catch {
                    cont.resume(throwing: SyncError.encodingFailed("\(error)"))
                }
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("HealthSync-iOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")",
                     forHTTPHeaderField: "User-Agent")
        // If you set INGEST_TOKEN on the pod, also set it here:
        // req.setValue("Bearer YOUR_TOKEN", forHTTPHeaderField: "Authorization")

        let (respData, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(IngestResult.self, from: respData)
    }
}
