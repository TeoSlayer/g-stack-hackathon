import SwiftUI

/// Shown on top of the TabView until Readiness is calibrated. Tells the user
/// *why* they're waiting (HK auth, first sync, model warmup) so the empty
/// state doesn't read as "broken". Replaces the dead white launch flash.
struct SplashView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared
    @State private var pulse = false
    @State private var ringRotation = 0.0
    @State private var appearedAt = Date()

    var body: some View {
        ZStack {
            // Base gradient — dark navy matching the launch screen + app icon.
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.14, blue: 0.20),
                         Color(red: 0.05, green: 0.07, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            // Vignette — radial darken toward the corners. Sells "depth" so the
            // flat gradient doesn't read as untextured wallpaper.
            RadialGradient(
                colors: [.clear, .black.opacity(0.45)],
                center: .center,
                startRadius: 80,
                endRadius: 520
            ).ignoresSafeArea()

            VStack(spacing: 24) {
                MascotLogo(pulse: $pulse, rotation: $ringRotation)
                    .frame(width: 140, height: 140)

                Text("HealthSync")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(spacing: 14) {
                    BootStep(label: "HealthKit authorization",
                             status: manager.authorizationStatus.hasPrefix("Granted") ? .done
                                   : (manager.authorizationStatus.hasPrefix("Denied") ? .failed : .running))
                    BootStep(label: "Server reachable",
                             status: manager.serverReachable ? .done : .running)
                    BootStep(label: "First sync",
                             status: manager.lastSyncDate != nil ? .done : .running)
                    BootStep(label: "Calibrating readiness",
                             status: manager.readiness.band == .unknown ? .running : .done)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 360)

                if !manager.currentActivity.isEmpty {
                    Text(manager.currentActivity)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 360)
                        .transition(.opacity)
                        .id(manager.currentActivity)
                }

                // Backfill hint: if we've been on the splash >4 s and still no
                // first sync, set expectation that initial backfill takes a
                // minute or two. Beats a frozen-looking spinner.
                if showsBackfillHint {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Backfilling last 30 days of HealthKit — usually 1–2 min on a typical Watch.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: 360)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // First-launch hint: when the iOS Health Access sheet is up,
                // the user sees a long list of toggles with no context.
                if manager.authorizationStatus == "—" {
                    Text("When the **Health Access** sheet appears, tap **Turn On All** so HealthSync can read your data. Nothing leaves your device without your say-so.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 360)
                        .padding(.top, 4)
                }
            }
        }
        .onAppear {
            appearedAt = Date()
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }

    /// Show the "this is normal, hang on" line if we've been here for >4 s and
    /// the first sync hasn't completed.
    private var showsBackfillHint: Bool {
        manager.lastSyncDate == nil
            && Date().timeIntervalSince(appearedAt) > 4
    }
}

/// Pulsing mascot logo with rotating angular-gradient ring. Uses the actual
/// app icon image so on-screen branding matches the home-screen icon.
private struct MascotLogo: View {
    @Binding var pulse: Bool
    @Binding var rotation: Double
    var body: some View {
        ZStack {
            // Outer rotating arc
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    AngularGradient(colors: [.pink.opacity(0.6), .purple, .blue, .pink.opacity(0.6)],
                                    center: .center),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
                .padding(4)
            // Pulsing inner glow
            Circle()
                .fill(.pink.opacity(0.22))
                .scaleEffect(pulse ? 0.95 : 0.7)
                .blur(radius: 18)
            // The actual app icon — clipped to a circle so the asset's square
            // background doesn't fight the rotating ring.
            Image("Mascot")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(Circle())
                .padding(14)
                .scaleEffect(pulse ? 1.04 : 1.0)
                .shadow(color: .pink.opacity(0.45), radius: pulse ? 16 : 8)
        }
    }
}

enum BootStepStatus { case running, done, failed }

struct BootStep: View {
    let label: String
    let status: BootStepStatus
    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch status {
                case .running:
                    ProgressView().controlSize(.small).tint(.white)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 20, height: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(status == .done ? 0.5 : 0.95))
            Spacer()
        }
        .animation(.easeInOut(duration: 0.3), value: status == .done)
    }
}
