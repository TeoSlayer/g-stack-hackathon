import SwiftUI
import HealthKit

/// Compact 35-day calendar grid where each cell is colour-coded by that day's
/// HRV vs the 7-day baseline ending at that day. Tap any cell for a sheet with
/// HRV / RHR / Sleep / Steps for that day.
struct CalendarView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @State private var days: [DayReading] = []
    @State private var loading = false
    @State private var selected: DayReading?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if loading && days.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading 35 days from HealthKit…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                grid
                legend
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Calendar")
        .refreshable { await reload() }
        .task { if days.isEmpty { await reload() } }
        .onReceive(manager.$cachedSeries.dropFirst()) { _ in
            Task { await reload() }
        }
        .sheet(item: $selected) { day in
            DayDetailSheet(day: day)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Text("Last 5 weeks").font(.subheadline.bold())
            Spacer()
            if loading && !days.isEmpty {
                ProgressView().controlSize(.small)
            }
            NavigationLink {
                LocationMapView()
            } label: {
                Label("Map", systemImage: "map")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
        }
        .padding(.horizontal)
    }

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: cols, spacing: 6) {
            // Index-based id — weekday letters duplicate (T/T, S/S) which
            // confuses ForEach's diffing.
            ForEach(Array(Self.weekdayHeaders.enumerated()), id: \.offset) { _, wd in
                Text(wd).font(.caption2.bold()).foregroundStyle(.secondary)
            }
            ForEach(days) { d in
                DayCell(day: d, isToday: Calendar.current.isDateInToday(d.date))
                    .onTapGesture { selected = d }
            }
        }
        .padding(.horizontal)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot(.green, "recovered")
            legendDot(.yellow, "moderate")
            legendDot(.red, "depleted")
            legendDot(.gray.opacity(0.35), "no data")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }
    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private static let weekdayHeaders: [String] = {
        let f = DateFormatter()
        f.locale = Locale.current
        let names = f.veryShortWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        let first = Calendar.current.firstWeekday - 1
        return Array(names[first...] + names[..<first])
    }()

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        days = await DayReading.lastFiveWeeks(store: manager.store)
    }
}

private struct DayCell: View {
    let day: DayReading
    let isToday: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(day.color)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isToday ? .white : .clear, lineWidth: 2)
                )
            VStack(spacing: 2) {
                Text(day.dayNum)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(day.hasData ? .white : .secondary)
                if let s = day.score {
                    Text("\(s)").font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(height: 42)
        .contentShape(Rectangle())
    }
}

private struct DayDetailSheet: View {
    let day: DayReading
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(day.longLabel).font(.title3.bold())
                        Spacer()
                        if let s = day.score {
                            Text("\(s)")
                                .font(.system(.title, design: .rounded).bold())
                                .foregroundColor(day.color)
                                .contentTransition(.numericText())
                        }
                    }
                    if let band = day.bandLabel {
                        Text(band).font(.subheadline.bold()).foregroundColor(day.color)
                    }
                }
                Section("Signals") {
                    metricRow("HRV (SDNN)",  value: day.hrv.map { String(format: "%.0f ms", $0) })
                    metricRow("Resting HR",  value: day.rhr.map { String(format: "%.0f bpm", $0) })
                    metricRow("Sleep",       value: day.sleepHours.map { String(format: "%.1f h", $0) })
                    metricRow("Steps",       value: day.steps.map { "\(Int($0))" })
                }
            }
            .navigationTitle("Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    private func metricRow(_ label: String, value: String?) -> some View {
        LabeledContent(label, value: value ?? "—")
            .foregroundStyle(value == nil ? .secondary : .primary)
    }
}

// MARK: - DayReading

struct DayReading: Identifiable {
    let id: Date
    let date: Date
    let hrv: Double?
    let rhr: Double?
    let sleepHours: Double?
    let steps: Double?
    /// HRV as percent of trailing-7-day baseline ending at this day.
    let percentOfBaseline: Double?

    var hasData: Bool { hrv != nil || rhr != nil || sleepHours != nil || steps != nil }
    var score: Int? {
        guard let p = percentOfBaseline else { return nil }
        return max(0, min(100, Int((p * 75).rounded())))
    }
    var bandLabel: String? {
        guard let p = percentOfBaseline else { return hasData ? "Not enough HRV data" : nil }
        switch p {
        case ..<0.85:  return "Depleted"
        case ..<1.10:  return "Moderate"
        default:        return "Recovered"
        }
    }
    var color: Color {
        guard let p = percentOfBaseline else { return .gray.opacity(0.25) }
        switch p {
        case ..<0.85:  return .red.opacity(0.85)
        case ..<1.10:  return .yellow.opacity(0.85)
        default:        return .green.opacity(0.85)
        }
    }
    var dayNum: String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: date)
    }
    var longLabel: String {
        date.formatted(.dateTime.weekday(.wide).month().day())
    }

    /// Load 35 days of state. Computes each day's HRV in parallel with its
    /// trailing-7-day baseline, so the grid colour reflects relative recovery
    /// (not raw HRV — which varies wildly between people).
    static func lastFiveWeeks(store: HKHealthStore) async -> [DayReading] {
        let total = 35
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Pull full 35-day series for cheap aggregates first; baseline needs a
        // wider window so query 42 days for HRV/RHR to have 7-day backcontext.
        async let hrvS   = TimeSeries.compute(kind: .hrv,   days: 42, forecastDays: 0, store: store)
        async let rhrS   = TimeSeries.compute(kind: .rhr,   days: total, forecastDays: 0, store: store)
        async let sleepS = TimeSeries.compute(kind: .sleep, days: total, forecastDays: 0, store: store)
        async let stepsS = TimeSeries.compute(kind: .steps, days: total, forecastDays: 0, store: store)
        let (h, r, sl, st) = await (hrvS, rhrS, sleepS, stepsS)

        let hrvByDay   = Dictionary(uniqueKeysWithValues: h.history.map  { (cal.startOfDay(for: $0.date), $0.value) })
        let rhrByDay   = Dictionary(uniqueKeysWithValues: r.history.map  { (cal.startOfDay(for: $0.date), $0.value) })
        let sleepByDay = Dictionary(uniqueKeysWithValues: sl.history.map { (cal.startOfDay(for: $0.date), $0.value) })
        let stepsByDay = Dictionary(uniqueKeysWithValues: st.history.map { (cal.startOfDay(for: $0.date), $0.value) })

        // Walk back from today, padding to fill the leading week so the grid aligns by weekday.
        var output: [DayReading] = []
        for i in (0..<total).reversed() {
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let hrvToday = hrvByDay[day]
            // Trailing 7-day baseline ENDING the day before (exclusive of today).
            var baselineVals: [Double] = []
            for j in 1...7 {
                if let prev = cal.date(byAdding: .day, value: -j, to: day),
                   let v = hrvByDay[prev] {
                    baselineVals.append(v)
                }
            }
            let baseline: Double? = baselineVals.isEmpty
                ? nil
                : baselineVals.sorted()[baselineVals.count / 2]
            let pct: Double? = {
                guard let t = hrvToday, let b = baseline, b > 0 else { return nil }
                return t / b
            }()
            output.append(DayReading(
                id: day, date: day,
                hrv: hrvToday, rhr: rhrByDay[day],
                sleepHours: sleepByDay[day], steps: stepsByDay[day],
                percentOfBaseline: pct
            ))
        }
        // Pad leading days so the first row starts on the locale's first weekday.
        guard let first = output.first?.date else { return output }
        let firstWeekday = cal.firstWeekday
        let firstDayWeekday = cal.component(.weekday, from: first)
        var leadingPad = firstDayWeekday - firstWeekday
        if leadingPad < 0 { leadingPad += 7 }
        // Guard against `1...0` — Swift Range requires lowerBound <= upperBound.
        // `1..<(leadingPad + 1)` is an empty (non-fatal) range when leadingPad == 0.
        var padded: [DayReading] = []
        for offset in 1..<(leadingPad + 1) {
            let d = cal.date(byAdding: .day, value: -offset, to: first)!
            // Use a tagged placeholder ID so a real DayReading with the same date
            // (rare but possible at month boundaries) doesn't collide.
            let placeholderID = cal.date(byAdding: .second, value: -1, to: d) ?? d
            padded.append(DayReading(id: placeholderID, date: d, hrv: nil, rhr: nil,
                                     sleepHours: nil, steps: nil, percentOfBaseline: nil))
        }
        return padded.reversed() + output
    }
}
