import WidgetKit
import SwiftUI
import Charts

@main
struct HealthSyncWidgetBundle: WidgetBundle {
    var body: some Widget {
        HealthSyncWidget()
    }
}

struct HealthSyncWidget: Widget {
    let kind = "HealthSyncWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HealthSyncWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HealthSync")
        .description("Last sync status at a glance.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .systemSmall,
            .systemMedium,
            .systemLarge,
        ])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: WidgetStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // One entry now; the app calls WidgetCenter.reloadAllTimelines() after each
        // sync, so we don't need a fanned-out schedule.
        let entry = Entry(date: Date(), snapshot: WidgetStore.read())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct HealthSyncWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCircular:    circular
        case .accessoryInline:      inline
        case .systemSmall:          small
        case .systemMedium:         medium
        case .systemLarge:          large
        default:                    small
        }
    }

    // MARK: lock-screen rectangular
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.text.square")
                Text(readinessScoreOrPlaceholder)
                    .font(.system(.title3, design: .rounded).bold())
                Text(readinessBandShort).font(.caption2).foregroundStyle(.secondary)
            }
            Text(readinessAdviceOrFallback)
                .font(.caption2)
                .lineLimit(2)
        }
    }

    // MARK: lock-screen circular
    private var circular: some View {
        ZStack {
            Circle().stroke(lineWidth: 2)
            VStack(spacing: 0) {
                Text(readinessScoreOrPlaceholder)
                    .font(.system(size: 18, design: .rounded).bold())
                Text("READY").font(.system(size: 8).bold()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: lock-screen inline
    private var inline: some View {
        Text("Readiness \(readinessScoreOrPlaceholder) · \(readinessBandShort)")
    }

    // MARK: home-screen small
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.text.square").foregroundStyle(statusColor)
                Text("Readiness").font(.subheadline.bold())
                Spacer(minLength: 0)
            }
            Text(readinessScoreOrPlaceholder)
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(statusColor)
            Text(readinessBandShort).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(readinessAdviceOrFallback)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Text(lastSyncRelative).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: home-screen medium — readiness + HRV sparkline with forecast
    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Readiness").font(.caption.bold()).foregroundStyle(.secondary)
                Text(readinessScoreOrPlaceholder)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(statusColor)
                Text(readinessBandShort).font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Text(readinessAdviceOrFallback).font(.caption2).lineLimit(2)
            }
            .frame(maxWidth: 130, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("HRV · 30d + 7d forecast").font(.caption2).foregroundStyle(.secondary)
                MiniSparkline(
                    history: entry.snapshot.hrvSeries,
                    forecast: entry.snapshot.hrvForecast,
                    tint: .blue
                )
            }
        }
    }

    // MARK: home-screen large — readiness + 3 sparklines
    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(readinessScoreOrPlaceholder)
                    .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Readiness · \(readinessBandShort)").font(.caption.bold())
                    Text(readinessAdviceOrFallback).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Divider()
            metricRow(label: "HRV",    unit: "ms",  history: entry.snapshot.hrvSeries,   forecast: entry.snapshot.hrvForecast,   tint: .blue)
            metricRow(label: "RestHR", unit: "bpm", history: entry.snapshot.rhrSeries,   forecast: entry.snapshot.rhrForecast,   tint: .pink)
            metricRow(label: "Sleep",  unit: "h",   history: entry.snapshot.sleepSeries, forecast: entry.snapshot.sleepForecast, tint: .indigo)
            Spacer(minLength: 0)
            Text(lastSyncRelative).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func metricRow(label: String, unit: String,
                           history: [MiniPoint], forecast: [MiniPoint],
                           tint: Color) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2.bold())
                Text("\(history.last.map { format($0.value) } ?? "—") \(unit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }.frame(width: 60, alignment: .leading)
            MiniSparkline(history: history, forecast: forecast, tint: tint)
                .frame(height: 28)
        }
    }

    private func format(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        if v >= 100    { return "\(Int(v.rounded()))" }
        if v >= 10     { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    private var readinessScoreOrPlaceholder: String {
        entry.snapshot.readinessScore.map(String.init) ?? "—"
    }
    private var readinessBandShort: String {
        switch entry.snapshot.readinessBand {
        case "recovered": return "Recovered"
        case "moderate":  return "Moderate"
        case "depleted":  return "Depleted"
        default:          return "Calibrating"
        }
    }
    private var readinessAdviceOrFallback: String {
        entry.snapshot.readinessAdvice ?? "Wear your watch overnight to calibrate."
    }

    // MARK: helpers

    private var statusSymbol: String {
        if !entry.snapshot.serverReachable { return "icloud.slash" }
        if entry.snapshot.isStale          { return "exclamationmark.circle" }
        return "heart.text.square"
    }
    /// Tint for the readiness number — falls back to a neutral grey when uncalibrated
    /// so the widget never lies about a score it doesn't have.
    private var statusColor: Color {
        switch entry.snapshot.readinessBand {
        case "recovered": return .green
        case "moderate":  return .yellow
        case "depleted":  return .red
        default:          return .secondary
        }
    }
    private var lastSyncRelative: String {
        guard let d = entry.snapshot.lastSyncDate else { return "Never synced" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "Synced \(f.localizedString(for: d, relativeTo: Date()))"
    }
    private var shortAgo: String {
        guard let d = entry.snapshot.lastSyncDate else { return "—" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 60        { return "\(s)s" }
        if s < 3600      { return "\(s/60)m" }
        if s < 86400     { return "\(s/3600)h" }
        return "\(s/86400)d"
    }
}

/// Compact sparkline: solid line over the history, dashed line over the forecast.
/// Falls back to a placeholder dash when either side is empty.
private struct MiniSparkline: View {
    let history: [MiniPoint]
    let forecast: [MiniPoint]
    let tint: Color
    var body: some View {
        if history.isEmpty {
            Text("—").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Chart {
                ForEach(history) { p in
                    LineMark(x: .value("d", p.date),
                             y: .value("v", p.value),
                             series: .value("k", "h"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(forecast) { p in
                    LineMark(x: .value("d", p.date),
                             y: .value("v", p.value),
                             series: .value("k", "f"))
                        .foregroundStyle(tint.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        }
    }
}
