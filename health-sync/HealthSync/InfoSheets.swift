import SwiftUI
import Charts

/// Reusable explanation sheet. Each metric / model can supply its own content
/// via the `Info` struct; the rendering is uniform.
struct Info {
    let title: String
    let oneLiner: String
    let what: String           // what is this
    let how: String            // how is it computed
    let what_to_do: String     // what to do with it
    let citation: String?
    let diagram: AnyView?      // optional inline diagram

    init(title: String, oneLiner: String, what: String, how: String,
         what_to_do: String, citation: String? = nil, diagram: AnyView? = nil) {
        self.title = title; self.oneLiner = oneLiner
        self.what = what; self.how = how; self.what_to_do = what_to_do
        self.citation = citation; self.diagram = diagram
    }
}

struct InfoSheet: View {
    let info: Info
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(info.oneLiner)
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 8)
                        .animation(.easeOut(duration: 0.35), value: revealed)

                    if let d = info.diagram {
                        d
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .opacity(revealed ? 1 : 0)
                            .animation(.easeOut(duration: 0.45).delay(0.05), value: revealed)
                    }

                    InfoSection(symbol: "questionmark.circle.fill",
                                color: .blue, title: "What is this",
                                text: info.what, delay: 0.10)
                    InfoSection(symbol: "function",
                                color: .purple, title: "How it's computed",
                                text: info.how, delay: 0.15)
                    InfoSection(symbol: "arrow.right.circle.fill",
                                color: .green, title: "What to do with it",
                                text: info.what_to_do, delay: 0.20)

                    if let cite = info.citation {
                        Divider().padding(.vertical, 8)
                        Label(cite, systemImage: "book.closed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            revealed = true
        }
    }
}

private struct InfoSection: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String
    let delay: Double
    @State private var revealed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(delay)) { revealed = true }
        }
    }
}

/// Tappable "ⓘ" that opens an Info sheet. Drop into any card's header.
struct InfoButton: View {
    let info: Info
    @State private var showing = false
    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .nonRepeating, value: showing)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            InfoSheet(info: info)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Diagrams

/// Three coloured bands with the current score's marker, used inside Readiness info.
struct ReadinessBandDiagram: View {
    let scoreFraction: Double  // 0..1
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(.red.opacity(0.75)).frame(width: geo.size.width * 0.45)
                        Rectangle().fill(.yellow.opacity(0.75)).frame(width: geo.size.width * 0.25)
                        Rectangle().fill(.green.opacity(0.75))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(radius: 1.5)
                        .offset(x: max(0, min(geo.size.width - 16, scoreFraction * geo.size.width - 8)))
                }
            }
            .frame(height: 20)

            HStack {
                Text("Depleted").font(.caption2).foregroundStyle(.red)
                Spacer()
                Text("Moderate").font(.caption2).foregroundStyle(.yellow)
                Spacer()
                Text("Recovered").font(.caption2).foregroundStyle(.green)
            }
        }
    }
}

/// Animated sample sparkline: a curve that draws itself when shown.
struct AnimatedSparkline: View {
    let values: [Double]
    let tint: Color
    @State private var progress: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            sparkPath(in: geo.size)
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 60)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2)) { progress = 1 }
        }
    }
    private func sparkPath(in size: CGSize) -> Path {
        guard values.count > 1,
              let minV = values.min(), let maxV = values.max(),
              maxV > minV else {
            return Path()
        }
        let stepX = size.width / CGFloat(values.count - 1)
        let scaleY = size.height
        var path = Path()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = (v - minV) / (maxV - minV)
            let y = size.height - CGFloat(normalized) * scaleY
            if i == 0 { path.move(to: .init(x: x, y: y)) }
            else      { path.addLine(to: .init(x: x, y: y)) }
        }
        return path
    }
}

/// Bell curve with shaded "today" zone — used in CUSUM / z-score explanations.
struct BellCurveDiagram: View {
    let highlightZ: Double   // standard deviations from mean
    var body: some View {
        Chart {
            ForEach(Array(stride(from: -3.0, through: 3.0, by: 0.1)), id: \.self) { z in
                LineMark(x: .value("z", z), y: .value("p", phi(z)))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(x: .value("you", highlightZ))
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .annotation(position: .top) {
                    Text(String(format: "you: %+.1f σ", highlightZ))
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: [-3, -2, -1, 0, 1, 2, 3]) { v in
                AxisGridLine()
                AxisValueLabel("\(v.as(Int.self) ?? 0)σ")
            }
        }
        .frame(height: 100)
    }
    private func phi(_ z: Double) -> Double {
        exp(-z * z / 2) / sqrt(2 * .pi)
    }
}

/// Stacked block diagram showing how Holt's method updates level + trend.
struct ExponentialSmoothingDiagram: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow("ℓ_t  =  α·x_t  +  (1−α)·(ℓ_{t−1} + b_{t−1})", caption: "level update")
            stepRow("b_t  =  β·(ℓ_t − ℓ_{t−1})  +  (1−β)·b_{t−1}", caption: "trend update")
            stepRow("ŷ_{t+h}  =  ℓ_t  +  h·b_t",                   caption: "forecast h-ahead")
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    private func stepRow(_ formula: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formula).font(.callout.monospaced())
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Info content for each metric / model

enum InfoContent {
    static let readiness = Info(
        title: "Readiness",
        oneLiner: "One number that tells you whether to push today or back off.",
        what: """
        A score from 0 to 100 derived from your overnight HRV (heart-rate variability) compared to your personal 7-day baseline. HRV is the gold-standard proxy for autonomic recovery — it goes up when your nervous system has rested, down when it hasn't.
        """,
        how: """
        Today: mean of HRV samples between yesterday midnight and 10am (or now). Baseline: median of the previous 7 nights' nightly means. Score = round(percent of baseline × 75), so 100% = score 75, ≥133% = 100.
        """,
        what_to_do: """
        Green (≥85): hard work today is fine. Yellow (60-85): normal day. Red (<60): your body is asking for rest. Sleep tonight, defer big workouts.
        """,
        citation: "Whoop/Oura methodology — overnight HRV vs rolling baseline",
        diagram: AnyView(ReadinessBandDiagram(scoreFraction: 0.78))
    )

    static let sleepRegularity = Info(
        title: "Sleep Regularity Index",
        oneLiner: "Are you going to bed at consistent times?",
        what: """
        Pairwise probability of being in the same sleep/wake state at the same minute-of-day, across every pair of days in a 14-day window. 100 = perfectly regular; 0 = completely random.

        This metric predicts cognitive performance and mood *better than total sleep duration* (Phillips et al.). Naps and weekend lie-ins don't hurt the score — only inconsistency does.
        """,
        how: """
        For each minute m of the 24-hour day and each day-pair (i,j): is your state the same? Sum across all minutes and pairs, normalize to 0-100.
        """,
        what_to_do: """
        Pick a fixed bedtime and hold it for a week. Sleep timing consistency does more for cognition than adding a half-hour. Aim for ≥75.
        """,
        citation: "Phillips et al., Scientific Reports"
    )

    static let autonomicBalance = Info(
        title: "Autonomic Balance",
        oneLiner: "Are both your stress signals pointing the wrong way?",
        what: """
        A composite z-score: HRV's direction minus RHR's direction over a 14-day window. Negative means HRV is down AND resting HR is up — a strong signal of accumulating stress, independent of any single noisy night.
        """,
        how: """
        z_HRV − z_RHR, where z = (today − 14-day mean) / 14-day stddev. Result in standard deviations; ±1σ is the rough "noticeable change" line.
        """,
        what_to_do: """
        Below −1σ: reduce load, sleep is the lever. Around 0: normal. Above +1σ: you're recovering well — train or push hard if you want.
        """,
        citation: "Composite z-score on standardized HRV/RHR",
        diagram: AnyView(BellCurveDiagram(highlightZ: -0.6))
    )

    static let sedentaryStress = Info(
        title: "Sedentary Stress",
        oneLiner: "How many minutes today did you sit still with an elevated heart rate?",
        what: """
        Time spent with HR above (RHR + 20 bpm) while step count for that hour is near zero. Classic "anxious at the desk" — your body in fight-or-flight while motionless. Often invisible to you, easy to miss for years.
        """,
        how: """
        Per hour: mean HR + step count. If steps < 200 AND HR > (your 14-day RHR + 20 bpm), the hour counts as 60 minutes of sedentary stress.
        """,
        what_to_do: """
        Stand up. Walk outside for five minutes. Do four cycles of box breathing (4-4-4-4). Sustained sedentary stress is the cardio-metabolic risk of knowledge work.
        """,
        citation: "Castaldo et al., J. Med. Eng. Tech."
    )

    static let cognitiveDebt = Info(
        title: "Cognitive Recovery Debt",
        oneLiner: "The sleep you owe yourself, weighted toward recent nights.",
        what: """
        Exponentially-weighted sum of (8h − actual sleep) over the last 7 nights. Recent nights count more than older ones, so the catch-up you did three nights ago doesn't fully erase the debt from last night.
        """,
        how: """
        debt = Σ w_t · max(0, 8h − sleep_t),  weights decay as e^(−daysAgo / 3).
        """,
        what_to_do: """
        < 3h: manageable. 3-6h: a recovery night this week. > 10h: cognition is measurably impaired right now — caffeine doesn't fix this, sleep does.
        """,
        citation: "EWMA sleep-debt accumulator"
    )

    static let burnoutCUSUM = Info(
        title: "Burnout Early Warning",
        oneLiner: "Has your resting heart rate quietly drifted up vs your baseline?",
        what: """
        CUSUM is a statistical change-detection algorithm from process control and epidemiology — the WHO uses it to spot disease outbreaks before they're obvious in raw counts. Same math applies to "outbreak of chronic stress."

        Chronic stress lifts resting HR 2-5 bpm over weeks before any subjective burnout signal. CUSUM accumulates small daily deviations, fires when they cross a threshold.
        """,
        how: """
        S_n = max(0, S_{n−1} + (x_n − μ_0 − k)),  alarm when S_n > h.

        μ_0 = baseline RHR (first half of history), k = σ/2 (slack), h = 5σ (threshold).
        """,
        what_to_do: """
        ALARM: scale back load this week, sleep more, audit caffeine. STABLE: nothing to do — RHR is in normal noise range.
        """,
        citation: "Page / Shewhart process-control statistic"
    )

    static let bedtimeDrift = Info(
        title: "Circadian Drift",
        oneLiner: "Is your bedtime walking later week by week?",
        what: """
        Non-parametric trend test (Mann-Kendall) on the last 14 nights' bedtimes. Robust to outliers — one wild night doesn't dominate. Outputs a p-value: low p + later direction = a real drift, not noise.
        """,
        how: """
        S = sum over all (i,j) pairs of sign(bedtime_j − bedtime_i). p from a standard-normal approximation. Direction = sign of S.
        """,
        what_to_do: """
        p < 0.05 with later direction: hold a lights-out time tonight. The drift compounds — one late night begets the next.
        """,
        citation: "Mann-Kendall non-parametric trend test"
    )

    static let kalmanHRV = Info(
        title: "HRV (Kalman-smoothed)",
        oneLiner: "Your 'true' current HRV after filtering out daily noise.",
        what: """
        State-space model: each daily HRV reading = the true underlying level + measurement noise. The Kalman filter estimates the level recursively, giving more weight to recent observations only when they're statistically surprising.

        Smoother than Holt for non-trended data; provides a confidence band as a free by-product.
        """,
        how: """
        Predict: P_t = P_{t−1} + Q. Update: K = P / (P + R), μ_t = μ_{t−1} + K(y_t − μ_{t−1}). Q and R are auto-tuned from the data (R = sample variance, Q = R/10).
        """,
        what_to_do: """
        Below smoothed line by ≥10%: your nervous system is unusually depleted today — easy day. Within 10%: normal.
        """,
        citation: "Local-level state-space (Kalman filter)"
    )

    // MARK: - Trend cards

    static let hrvTrend = Info(
        title: "Heart-Rate Variability",
        oneLiner: "The single most-validated proxy for autonomic recovery.",
        what: """
        HRV-SDNN: the standard deviation of beat-to-beat intervals over a measurement window. High = parasympathetic (rested) nervous system. Low = sympathetic (stressed). Highly individual — your "normal" is what matters, not population averages.
        """,
        how: """
        Daily mean of all HRV-SDNN samples Apple Watch recorded that day. Smoothed line uses Holt's exponential smoothing (α=0.3, β=0.1). Forecast is "if recent trend continues."
        """,
        what_to_do: """
        Trending up over 7 days: recovery on track. Trending down with a steady RHR: investigate sleep / alcohol / stress.
        """,
        citation: "Task Force of ESC/NASPE standards",
        diagram: AnyView(ExponentialSmoothingDiagram())
    )

    static let rhrTrend = Info(
        title: "Resting Heart Rate",
        oneLiner: "Lower over weeks = fitter or more recovered. Drifting up = chronic stress signal.",
        what: """
        The average heart rate during quiet, awake-but-still moments. Apple Watch computes this from motion-free windows during the day. Highly stable in healthy adults; multi-bpm weekly drift is meaningful.
        """,
        how: """
        Daily mean of resting heart rate samples (.discreteAverage statistic). 7-day rolling mean overlay, 7-day Holt forecast.
        """,
        what_to_do: """
        Drifting up 3+ bpm over a week: investigate. Caffeine, alcohol, illness, overtraining, or sustained stress. Check the Burnout CUSUM card.
        """,
        citation: "Task Force of ESC/NASPE standards"
    )

    static let sleepTrend = Info(
        title: "Sleep Duration",
        oneLiner: "Hours actually asleep each night — independent of time spent in bed.",
        what: """
        Total time the watch detected actual sleep (any asleep stage). Excludes the in-bed envelope. Daily granularity. Long-term mean matters more than any single night.
        """,
        how: """
        Per night: sum durations of all 'asleep' category samples, attributed to the wake-day. So a Mon night counts as Tuesday's sleep on the chart.
        """,
        what_to_do: """
        See the Cognitive Recovery Debt card for the actionable version. For trend: aim for the 7-day mean to be ≥7 h.
        """,
        citation: "Apple HealthKit sleep stages"
    )

    static let stepsTrend = Info(
        title: "Daily Steps",
        oneLiner: "Crude but unfakeable activity baseline.",
        what: """
        Total daily step count. Imperfect (doesn't capture cycling, lifting, swimming) but useful as a sedentary-vs-active proxy — and the easiest to act on.
        """,
        how: """
        Daily sum of step samples (.cumulativeSum statistic). 7-day Holt forecast.
        """,
        what_to_do: """
        < 5k/day average → add walks. 8-12k is the bulk of the cardio-metabolic benefit; beyond ~15k returns flatten.
        """,
        citation: "Saint-Maurice et al., JAMA"
    )
}

private extension Double {
    func `as`<T>(_ type: T.Type) -> T? where T: BinaryInteger {
        T(exactly: self.rounded())
    }
}
