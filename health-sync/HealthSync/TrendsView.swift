import SwiftUI
import Charts
import HealthKit

/// Dedicated trends/forecasts page. Loads on appear, refreshes after every sync
/// (`HealthSyncManager.lastSyncDate` change), and supports pull-to-refresh.
struct TrendsView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @State private var series: [MetricKind: MetricSeries] = [:]
    @State private var loading = false

    var body: some View {
        List {
            if series.isEmpty && loading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        VStack(alignment: .leading) {
                            Text("Computing trends…").font(.subheadline.bold())
                            Text("First load reads 30 days from HealthKit").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            ForEach(MetricKind.allCases) { kind in
                Section {
                    if let s = series[kind] {
                        MetricCard(series: s)
                    } else if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Querying \(kind.rawValue.lowercased())…")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No data.").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                        Text(kind.rawValue)
                        if let info = info(for: kind) {
                            InfoButton(info: info)
                        }
                    }
                }
            }
            Section {
                Text("Forecasts use Holt's exponential smoothing on 30 days of daily aggregates. Lines past today are *projections* of recent trend — they hold only \"if nothing changes\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Trends")
        .refreshable { await reload() }
        .task { if series.isEmpty { await reload() } }
        .onReceive(manager.$lastSyncDate.dropFirst()) { _ in
            Task { await reload() }
        }
        .overlay(alignment: .top) {
            if loading && !series.isEmpty {
                ProgressView().padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 4)
            }
        }
    }

    private func info(for kind: MetricKind) -> Info? {
        switch kind {
        case .hrv:   return InfoContent.hrvTrend
        case .rhr:   return InfoContent.rhrTrend
        case .sleep: return InfoContent.sleepTrend
        case .steps: return InfoContent.stepsTrend
        }
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        // Prefer the manager's cache — populated once per syncAll.
        // Fall back to direct compute only if the cache is empty (first launch
        // before any sync has finished).
        if !manager.cachedSeries.isEmpty {
            series = manager.cachedSeries
            return
        }
        for kind in MetricKind.allCases {
            let s = await TimeSeries.compute(kind: kind, store: manager.store)
            series[kind] = s
        }
    }
}

/// One metric card: trend pill + chart.
private struct MetricCard: View {
    let series: MetricSeries
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(latestText)
                    .font(.system(.title, design: .rounded).bold())
                if !series.history.isEmpty {
                    TrendPill(series: series).padding(.leading, 4)
                }
                Spacer()
                Text(forecastText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if series.history.isEmpty {
                Text("No data in the last 30 days.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 30)
            } else {
                MetricChart(series: series).frame(height: 160)
            }
        }
        .padding(.vertical, 4)
    }
    private var latestText: String {
        guard let last = series.history.last else { return "—" }
        return formatValue(last.value, kind: series.kind)
    }
    private var forecastText: String {
        guard let f = series.forecast.last else { return "" }
        let trend = series.trendPerDay
        let arrow = trend > 0.001 ? "↗︎" : (trend < -0.001 ? "↘︎" : "→")
        return "7-day: \(arrow) \(formatValue(f.value, kind: series.kind))"
    }
}

/// Up/down pill comparing the last value to the 7-day rolling mean.
/// Colour reflects whether the direction is *good* for that metric.
private struct TrendPill: View {
    let series: MetricSeries
    var body: some View {
        let (text, color) = pill
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var pill: (String, Color) {
        let hist = series.history
        guard let last = hist.last?.value, hist.count >= 7 else { return ("—", .secondary) }
        let recent7 = hist.suffix(7).map(\.value)
        let mean = recent7.reduce(0, +) / Double(recent7.count)
        guard mean > 0 else { return ("—", .secondary) }
        let pctDelta = (last - mean) / mean * 100
        let sign = pctDelta >= 0 ? "+" : ""
        let dir: MetricKind.Direction = pctDelta >= 0 ? .up : .down
        let good = dir == series.kind.goodDirection
        let color: Color = abs(pctDelta) < 2 ? .secondary : (good ? .green : .orange)
        return ("\(sign)\(Int(pctDelta.rounded()))%", color)
    }
}

private struct MetricChart: View {
    let series: MetricSeries
    var body: some View {
        Chart {
            ForEach(series.history) { p in
                LineMark(x: .value("Day", p.date, unit: .day),
                         y: .value("Value", p.value),
                         series: .value("kind", "history"))
                    .foregroundStyle(.primary.opacity(0.55))
                PointMark(x: .value("Day", p.date, unit: .day),
                          y: .value("Value", p.value))
                    .symbolSize(12)
                    .foregroundStyle(.primary.opacity(0.55))
            }
            ForEach(series.smoothed) { p in
                LineMark(x: .value("Day", p.date, unit: .day),
                         y: .value("Smoothed", p.value),
                         series: .value("kind", "smoothed"))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(series.forecast) { p in
                LineMark(x: .value("Day", p.date, unit: .day),
                         y: .value("Forecast", p.value),
                         series: .value("kind", "forecast"))
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            if let lastHist = series.history.last?.date {
                RuleMark(x: .value("Today", lastHist))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("today").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }
}

private func formatValue(_ v: Double, kind: MetricKind) -> String {
    switch kind {
    case .steps:
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        return "\(Int(v.rounded()))"
    case .sleep:
        return String(format: "%.1f h", v)
    case .hrv, .rhr:
        return "\(Int(v.rounded())) \(kind.unitLabel)"
    }
}
