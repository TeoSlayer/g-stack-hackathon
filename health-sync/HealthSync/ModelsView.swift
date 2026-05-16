import SwiftUI
import Charts

/// Dedicated "Models" tab. One card per model. Each shows: the value, a band
/// colour, a single suggested action, the citation, and (when available) an
/// inline mini-chart of the underlying history.
struct ModelsView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @State private var readings: [ModelReading] = []
    @State private var loading = false

    var body: some View {
        List {
            if readings.isEmpty && loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        VStack(alignment: .leading) {
                            Text("Running models…").font(.subheadline.bold())
                            Text("Seven analyses, each ~100 ms. SRI scans a 14×1440 minute matrix.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else if readings.isEmpty {
                Section {
                    Text("No model output yet. Pull to refresh or wait for the next sync.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(readings) { r in
                Section {
                    ModelCard(reading: r)
                }
            }
            Section {
                Text("Each model runs on-device with the citation on its card. Bands: green = good, blue = ok, orange = watch, red = act on it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Models")
        .refreshable { await reload() }
        .task { if readings.isEmpty { await reload() } }
        .onReceive(manager.$lastSyncDate.dropFirst()) { _ in
            Task { await reload() }
        }
        .overlay(alignment: .top) {
            if loading && !readings.isEmpty {
                ProgressView().padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 4)
            }
        }
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        // Read from manager's already-computed state when available; otherwise
        // run a one-off compute (e.g. when the user opens this tab before any
        // sync has finished).
        if !manager.modelReadings.isEmpty {
            readings = manager.modelReadings
            return
        }
        readings = await Models.computeAll(store: manager.store, cache: manager.cachedSeries)
    }
}

private struct ModelCard: View {
    let reading: ModelReading
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.title).font(.subheadline.bold())
                if let info = infoFor(reading.id) {
                    InfoButton(info: info)
                }
                Spacer()
                Text(reading.valueText)
                    .font(.system(.title3, design: .rounded).monospacedDigit().bold())
                    .foregroundColor(color)
                    .contentTransition(.numericText())
            }
            Text(reading.action)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !reading.series.isEmpty {
                ModelChart(reading: reading)
                    .frame(height: 90)
            }
            if !reading.detail.isEmpty {
                Text(reading.detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch reading.band {
        case .good:    return .green
        case .ok:      return .blue
        case .warn:    return .orange
        case .bad:     return .red
        case .unknown: return .secondary
        }
    }

    private func infoFor(_ id: ModelKind) -> Info? {
        switch id {
        case .sleepRegularity:  return InfoContent.sleepRegularity
        case .autonomicBalance: return InfoContent.autonomicBalance
        case .sedentaryStress:  return InfoContent.sedentaryStress
        case .cognitiveDebt:    return InfoContent.cognitiveDebt
        case .burnoutCUSUM:     return InfoContent.burnoutCUSUM
        case .bedtimeDrift:     return InfoContent.bedtimeDrift
        case .kalmanHRV:        return InfoContent.kalmanHRV
        }
    }
}

private struct ModelChart: View {
    let reading: ModelReading
    var body: some View {
        Chart {
            ForEach(reading.series) { p in
                LineMark(x: .value("d", p.date),
                         y: .value("v", p.value),
                         series: .value("k", "raw"))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            ForEach(reading.smoothed) { p in
                LineMark(x: .value("d", p.date),
                         y: .value("v", p.value),
                         series: .value("k", "smoothed"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}
