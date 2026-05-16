import Foundation

struct SyncEndpoint {
    let baseURL: String
    let deviceID: String
    let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = true   // even on cellular we'll try; failure is benign
        return URLSession(configuration: cfg)
    }()

    struct IngestResult: Decodable {
        let accepted: Int
        let duplicate: Int
        let rejected: Int
    }

    enum SyncError: Error {
        case badURL, badResponse(Int), encodingFailed
    }

    func healthz() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/healthz") else { throw SyncError.badURL }
        let (_, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return true
    }

    func ingest(samples: [[String: Any]], metadata: [String: Any]? = nil) async throws -> IngestResult {
        guard let url = URL(string: "\(baseURL)/ingest") else { throw SyncError.badURL }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let deviceID = self.deviceID
        let meta = metadata ?? [:]
        // Push JSON encoding to a background queue — for 200-sample chunks this
        // is ~100KB of dict→JSON work, blocking the main actor if left inline.
        // `isValidJSONObject` is a defensive pre-check: it returns false for
        // non-JSON keys/values so we throw cleanly instead of letting
        // JSONSerialization raise an unrecoverable NSException.
        let data: Data = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let body: [String: Any] = [
                    "device_id":   deviceID,
                    "app_version": appVersion,
                    "samples":     samples,
                    "metadata":    meta,
                ]
                guard JSONSerialization.isValidJSONObject(body) else {
                    cont.resume(throwing: SyncError.encodingFailed); return
                }
                do {
                    let d = try JSONSerialization.data(withJSONObject: body)
                    cont.resume(returning: d)
                } catch {
                    cont.resume(throwing: SyncError.encodingFailed)
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
