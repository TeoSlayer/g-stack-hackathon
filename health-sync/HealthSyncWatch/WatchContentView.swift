import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var manager: WatchHealthManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("HealthSync").font(.headline)

                if let hr = manager.currentHeartRate {
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                        Text("\(Int(hr)) bpm").font(.title2.monospacedDigit())
                    }
                } else {
                    Text("Waiting for heart rate…").foregroundStyle(.secondary).font(.footnote)
                }

                Divider()

                LabeledRow(
                    label: "Phone",
                    value: manager.phoneReachable ? "reachable" : "not paired",
                    ok: manager.phoneReachable
                )
                LabeledRow(
                    label: "Server",
                    value: manager.phoneServerReachable ? "reachable" : "offline",
                    ok: manager.phoneServerReachable
                )
                if let last = manager.phoneLastSync {
                    LabeledRow(label: "Last sync", value: Self.relative(last), ok: true)
                }

                Button(action: manager.requestPhoneSync) {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
        }
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }
}
