import Foundation
import CoreLocation

/// Pointy-top hexagonal grid in axial (q, r) coordinates over a flat projection
/// centered at a reference lat/lon. Good enough for city/region scale (≲50 km);
/// breaks down near the poles or at continental scale. We don't need H3 for that.
struct HexCoord: Hashable {
    let q: Int
    let r: Int
}

enum HexGrid {
    /// Convert lat/lon → flat XY meters, snap to hex, return axial coord.
    static func hex(for coord: CLLocationCoordinate2D,
                    origin: CLLocationCoordinate2D,
                    edgeSize: Double) -> HexCoord {
        let (x, y) = toMeters(coord, origin: origin)
        return axialFromPoint(x: x, y: y, size: edgeSize)
    }

    /// Hex polygon corners in lat/lon for rendering, given the same origin/size.
    static func corners(of hex: HexCoord,
                        origin: CLLocationCoordinate2D,
                        edgeSize: Double) -> [CLLocationCoordinate2D] {
        let (cx, cy) = centerMeters(of: hex, size: edgeSize)
        return (0..<6).map { i in
            let angle = .pi / 180 * (60.0 * Double(i) - 30)  // pointy-top: −30° offset
            let x = cx + edgeSize * cos(angle)
            let y = cy + edgeSize * sin(angle)
            return fromMeters(x: x, y: y, origin: origin)
        }
    }

    // MARK: - Projection (equirectangular)

    private static let earthR = 6_371_000.0

    private static func toMeters(_ c: CLLocationCoordinate2D,
                                 origin: CLLocationCoordinate2D) -> (Double, Double) {
        let dLat = (c.latitude - origin.latitude) * .pi / 180
        let dLon = (c.longitude - origin.longitude) * .pi / 180
        let originLatRad = origin.latitude * .pi / 180
        let x = dLon * cos(originLatRad) * earthR
        let y = dLat * earthR
        return (x, y)
    }

    private static func fromMeters(x: Double, y: Double,
                                   origin: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let originLatRad = origin.latitude * .pi / 180
        let dLat = y / earthR * 180 / .pi
        let dLon = x / (earthR * cos(originLatRad)) * 180 / .pi
        return CLLocationCoordinate2D(latitude: origin.latitude + dLat,
                                       longitude: origin.longitude + dLon)
    }

    // MARK: - Hex math (pointy-top, axial coords)

    private static func centerMeters(of hex: HexCoord, size: Double) -> (Double, Double) {
        let x = size * (sqrt(3.0) * Double(hex.q) + sqrt(3.0) / 2 * Double(hex.r))
        let y = size * (3.0 / 2 * Double(hex.r))
        return (x, y)
    }

    private static func axialFromPoint(x: Double, y: Double, size: Double) -> HexCoord {
        let qf = (sqrt(3.0) / 3 * x - 1.0 / 3 * y) / size
        let rf = (2.0 / 3 * y) / size
        return cubeRound(qf: qf, rf: rf)
    }

    /// Round fractional axial to nearest hex via cube coordinates.
    private static func cubeRound(qf: Double, rf: Double) -> HexCoord {
        let xf = qf
        let zf = rf
        let yf = -xf - zf
        var rx = (xf).rounded()
        var ry = (yf).rounded()
        var rz = (zf).rounded()
        let dx = abs(rx - xf), dy = abs(ry - yf), dz = abs(rz - zf)
        if dx > dy && dx > dz { rx = -ry - rz }
        else if dy > dz       { ry = -rx - rz }
        else                  { rz = -rx - ry }
        return HexCoord(q: Int(rx), r: Int(rz))
    }
}

/// Aggregated metric for one hex cell.
struct HexCell: Identifiable {
    let id: HexCoord
    let polygon: [CLLocationCoordinate2D]
    let center: CLLocationCoordinate2D
    let count: Int
    let value: Double?    // chosen metric's mean across samples in this cell

    var coord: HexCoord { id }
}

enum MapMetric: String, CaseIterable, Identifiable {
    case heartRate   = "Heart Rate"
    case hrv         = "HRV (overnight, day-of)"
    case rhr         = "Resting HR (day-of)"
    case visits      = "Visit density"
    case speed       = "Speed"

    var id: String { rawValue }
    var unitLabel: String {
        switch self {
        case .heartRate: return "bpm"
        case .hrv:       return "ms"
        case .rhr:       return "bpm"
        case .visits:    return ""
        case .speed:     return "m/s"
        }
    }
    /// For HRV, higher is better → reverse the colour ramp.
    var higherIsBetter: Bool {
        switch self {
        case .hrv:                       return true
        case .heartRate, .rhr, .speed:   return false
        case .visits:                    return false  // density is neutral, use sequential ramp
        }
    }
}

enum HexAgg {
    /// Bin samples and compute the cell-level value for each `MapMetric`.
    static func aggregate(samples: [LocatedSample], metric: MapMetric,
                          edgeSize: Double) -> [HexCell] {
        guard let firstCoord = samples.first?.coordinate else { return [] }
        let origin = firstCoord  // arbitrary anchor for the local projection

        var groups: [HexCoord: [LocatedSample]] = [:]
        for s in samples {
            let h = HexGrid.hex(for: s.coordinate, origin: origin, edgeSize: edgeSize)
            groups[h, default: []].append(s)
        }
        return groups.map { (coord, members) in
            let value: Double? = {
                switch metric {
                case .heartRate:
                    let vs = members.compactMap(\.heartRate)
                    return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
                case .hrv:
                    let vs = members.compactMap(\.dailyHRV)
                    return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
                case .rhr:
                    let vs = members.compactMap(\.dailyRHR)
                    return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
                case .visits:
                    return Double(members.count)
                case .speed:
                    let vs = members.compactMap(\.speedMPS)
                    return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
                }
            }()
            return HexCell(
                id: coord,
                polygon: HexGrid.corners(of: coord, origin: origin, edgeSize: edgeSize),
                center: HexGrid.corners(of: coord, origin: origin, edgeSize: edgeSize)
                    .first ?? origin,  // close enough for label placement
                count: members.count,
                value: value
            )
        }
    }
}
