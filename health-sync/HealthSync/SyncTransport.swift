import Foundation

/// Transport-agnostic interface for shipping HK samples off-device.
///
/// `HealthSyncManager` doesn't care whether the bytes go over HTTP to a pod or
/// over the Pilot overlay to an OpenClaw skill — it just calls `ingest(...)`
/// and `ping()`. Each concrete implementation handles its own framing,
/// encryption, and error semantics.
///
/// Pacing, retry, outbox, and anchor commit live in the manager (or the
/// future `OutboxWorker`); transports are *fire-once, return-result* primitives.
protocol SyncTransport: Sendable {
    /// Stable identifier for logs / UI ("http", "pilot").
    var kind: TransportKind { get }
    /// Reachability probe. Returns `true` if the destination answered healthily.
    func ping() async -> Bool
    /// Ship one envelope's worth of samples plus optional envelope metadata.
    /// Throws on transport / framing failure. Returns the destination's
    /// accept / duplicate / reject counts.
    func ingest(samples: [[String: Any]], metadata: [String: Any]?) async throws -> IngestResult
}

/// Which transport `HealthSyncManager` should use. Persisted to UserDefaults.
enum TransportKind: String, CaseIterable, Identifiable, Codable {
    case http
    case pilot

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .http:  return "HTTP (pod)"
        case .pilot: return "Pilot overlay"
        }
    }
    var symbol: String {
        switch self {
        case .http:  return "network"
        case .pilot: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// Result of one ingest. Shape matches the JSON the pod returns today; the
/// Pilot adapter returns the same shape after parsing the ack envelope.
struct IngestResult: Decodable, Equatable {
    let accepted:  Int
    let duplicate: Int
    let rejected:  Int
}

/// Errors raised by any transport. Concrete transports map their native
/// error spaces (URLError, Pilot.Error, …) onto this enum so the manager has
/// one error type to reason about.
enum SyncError: Error, CustomStringConvertible {
    case badURL
    case badResponse(Int)
    case encodingFailed(String)
    case notImplemented(String)
    case transport(String)

    var description: String {
        switch self {
        case .badURL:                 return "bad URL"
        case .badResponse(let code):  return "bad response \(code)"
        case .encodingFailed(let s):  return "encoding failed: \(s)"
        case .notImplemented(let s):  return "not implemented: \(s)"
        case .transport(let s):       return "transport: \(s)"
        }
    }
}

/// Walk a candidate JSON body, return a path+description of the first value
/// that JSONSerialization will reject. Used by transports to turn the silent
/// `encodingFailed` into something actionable in the event log.
func describeInvalidJSON(_ obj: Any, path: String = "$") -> String? {
    if let dict = obj as? [String: Any] {
        for (k, v) in dict {
            if let p = describeInvalidJSON(v, path: "\(path).\(k)") { return p }
        }
        return nil
    }
    if let arr = obj as? [Any] {
        for (i, v) in arr.enumerated() {
            if let p = describeInvalidJSON(v, path: "\(path)[\(i)]") { return p }
        }
        return nil
    }
    if obj is String || obj is NSString || obj is NSNull { return nil }
    if let n = obj as? NSNumber {
        // Strings, Bools, all integers and Double/Float bridge to NSNumber.
        // NSNumber detects Bool via objCType == "c" but JSON accepts Bool fine.
        let d = n.doubleValue
        if d.isNaN || d.isInfinite {
            return "\(path) NaN/Inf (\(type(of: obj)))"
        }
        return nil
    }
    return "\(path) unsupported type: \(type(of: obj)) value=\(obj)"
}
