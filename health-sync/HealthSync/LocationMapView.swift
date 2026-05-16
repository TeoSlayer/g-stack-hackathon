import SwiftUI
import MapKit
import HealthKit
import CoreLocation

/// Hex heatmap of your location-tagged HK data. Spectrum switches the metric
/// being plotted (HR, HRV, RHR, visit density, speed). Built from historical
/// `HKWorkoutRoute` data — every outdoor workout you've recorded contributes.
struct LocationMapView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @State private var readings: [LocatedReading] = []
    @State private var cells: [HexCell] = []
    @State private var metric: MapMetric = .hrv
    @State private var edgeMeters: Double = 400
    @State private var daysBack: Double = 90
    @State private var loading = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var stats: (vMin: Double, vMax: Double, count: Int) = (0, 1, 0)
    @State private var photosAuthBanner: PhotoBannerState = .checking

    enum PhotoBannerState { case checking, granted, missing }

    /// Target hexes across the smaller visible-region dimension. Higher → finer
    /// grid, smaller hexes; lower → coarser, bigger hexes. ~30 is the sweet
    /// spot where hexes are big enough to see at any zoom and small enough to
    /// resolve distinct places.
    private let targetHexesAcross: Double = 30
    private let minEdgeMeters: Double = 30
    private let maxEdgeMeters: Double = 8000

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.polygon)
                        .foregroundStyle(color(for: cell).opacity(0.55))
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .onMapCameraChange(frequency: .onEnd) { ctx in
                adjustHexSize(for: ctx.region)
            }

            VStack(spacing: 8) {
                LegendBar(metric: metric, vMin: stats.vMin, vMax: stats.vMax)
                MetricPicker(metric: $metric)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "hexagon")
                        Text("\(formatEdge(edgeMeters))").font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(value: $daysBack, in: 7...365, step: 7) {
                        Text("\(Int(daysBack))d").font(.caption.monospacedDigit())
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 4)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .opacity(loading && readings.isEmpty ? 0.65 : 1)

            if loading && readings.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Joining HK to your photo geotags…")
                        .font(.subheadline.bold())
                    Text("\(Int(daysBack)) days · HRV / RHR / HR samples ± 2h photo match")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else if readings.isEmpty && !loading {
                VStack(spacing: 10) {
                    Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No located readings yet").font(.subheadline.bold())
                    if photosAuthBanner == .missing {
                        Text("Allow Photos access in Settings → Privacy → Photos → HealthSync. Geotagged photos give us a retroactive location for every HK sample.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Request Photos access") {
                            Task {
                                _ = await PhotosLocationProvider.requestAuth()
                                photosAuthBanner = PhotosLocationProvider.authStatus == .authorized
                                    || PhotosLocationProvider.authStatus == .limited ? .granted : .missing
                                await reload()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("No HK samples in window had a geotagged photo within ±2 h. Widen the days range or take more photos outdoors.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
            }
        }
        .navigationTitle("Location Heatmap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task {
            await checkPhotosAuth()
            if readings.isEmpty { await reload() }
        }
        .onChange(of: metric) { _, _ in recomputeCells() }
        .onChange(of: edgeMeters) { _, _ in recomputeCells() }
        .onChange(of: daysBack) { _, _ in Task { await reload() } }
    }

    private func checkPhotosAuth() async {
        let s = PhotosLocationProvider.authStatus
        if s == .notDetermined {
            _ = await PhotosLocationProvider.requestAuth()
        }
        let updated = PhotosLocationProvider.authStatus
        photosAuthBanner = (updated == .authorized || updated == .limited) ? .granted : .missing
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        readings = await LocationSources.fetchAll(daysBack: Int(daysBack), store: manager.store)
        recomputeCells()
        if let region = boundingRegion(coords: readings.map(\.coordinate)) {
            camera = .region(region)
        }
    }

    private func recomputeCells() {
        let cs = HexAgg.aggregate(readings: readings, metric: metric, edgeSize: edgeMeters)
        cells = cs
        let vals = cs.compactMap(\.value)
        let lo = vals.min() ?? 0
        let hi = vals.max() ?? 1
        stats = (lo, max(hi, lo + 0.0001), cs.count)
    }

    /// Re-pick hex edge based on the visible region. Bigger hexes when zoomed
    /// out, smaller when zoomed in — so cells are always roughly the same
    /// on-screen size. Only recomputes if the change is ≥15 % to avoid jitter
    /// during small pan/pinch deltas.
    private func adjustHexSize(for region: MKCoordinateRegion) {
        let latMeters = region.span.latitudeDelta * 111_000
        let cosLat = cos(region.center.latitude * .pi / 180)
        let lonMeters = region.span.longitudeDelta * 111_000 * max(cosLat, 0.01)
        let visibleSpan = min(latMeters, lonMeters)
        guard visibleSpan > 0 else { return }
        let target = (visibleSpan / targetHexesAcross)
            .clamped(to: minEdgeMeters...maxEdgeMeters)
        // Snap to a tidy step so the readout doesn't bounce between 187 / 192 / 201 m.
        let snapped = snapToBucket(target)
        guard abs(snapped - edgeMeters) / max(edgeMeters, 1) > 0.15 else { return }
        edgeMeters = snapped
        recomputeCells()
    }

    /// Round to the nearest "nice" hex size so the user sees stable numbers.
    private func snapToBucket(_ x: Double) -> Double {
        let buckets: [Double] = [
            30, 50, 80, 120, 200, 300, 500, 800,
            1200, 2000, 3000, 5000, 8000
        ]
        return buckets.min(by: { abs($0 - x) < abs($1 - x) }) ?? x
    }

    private func formatEdge(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m / 1000) }
        return "\(Int(m)) m"
    }

    private func color(for cell: HexCell) -> Color {
        guard let v = cell.value else { return .gray.opacity(0.4) }
        let span = max(stats.vMax - stats.vMin, 0.0001)
        var t = (v - stats.vMin) / span
        if metric.higherIsBetter { t = 1 - t }
        return ramp(t.clamped(to: 0...1))
    }

    /// Red → orange → yellow → green ramp (good=green).
    private func ramp(_ t: Double) -> Color {
        switch t {
        case ..<0.25: return blend(.red,    .orange, t * 4)
        case ..<0.50: return blend(.orange, .yellow, (t - 0.25) * 4)
        case ..<0.75: return blend(.yellow, .green,  (t - 0.50) * 4)
        default:       return .green
        }
    }
    private func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let aC = UIColor(a).cgColor.components ?? [1,1,1,1]
        let bC = UIColor(b).cgColor.components ?? [1,1,1,1]
        return Color(
            red:   aC[0] + (bC[0] - aC[0]) * t,
            green: aC[1] + (bC[1] - aC[1]) * t,
            blue:  aC[2] + (bC[2] - aC[2]) * t
        )
    }

    private func boundingRegion(coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.01, (maxLat - minLat) * 1.25),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.25)
        )
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

private struct MetricPicker: View {
    @Binding var metric: MapMetric
    var body: some View {
        Picker("Metric", selection: $metric) {
            ForEach(MapMetric.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
    }
}

private struct LegendBar: View {
    let metric: MapMetric
    let vMin: Double
    let vMax: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(metric.rawValue)").font(.caption.bold())
                Spacer()
                Text(metric.higherIsBetter ? "higher = good" : "higher = worse / more")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: metric.higherIsBetter
                        ? [.red, .orange, .yellow, .green]
                        : [.green, .yellow, .orange, .red],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 8)
                .clipShape(Capsule())
            }
            HStack {
                Text(label(vMin)).font(.caption2.monospacedDigit())
                Spacer()
                Text(label((vMin + vMax) / 2)).font(.caption2.monospacedDigit())
                Spacer()
                Text(label(vMax)).font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
    }
    private func label(_ v: Double) -> String {
        if !v.isFinite { return "—" }
        switch metric {
        case .visits: return "\(Int(v.rounded()))"
        case .speed:  return String(format: "%.1f m/s", v)
        default:      return "\(Int(v.rounded())) \(metric.unitLabel)"
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
