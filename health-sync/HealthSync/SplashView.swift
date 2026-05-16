import SwiftUI

/// Shown on top of the TabView until Readiness is calibrated. Tells the user
/// *why* they're waiting (HK auth, first sync, model warmup) so the empty
/// state doesn't read as "broken". Replaces the dead white launch flash.
struct SplashView: View {
    @EnvironmentObject var manager: HealthSyncManager
    @ObservedObject var net = NetworkMonitor.shared
    @State private var pulse = false
    @State private var ringRotation = 0.0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.14, blue: 0.20),
                         Color(red: 0.05, green: 0.07, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 28) {
                AnimatedHeartLogo(pulse: $pulse, rotation: $ringRotation)
                    .frame(width: 120, height: 120)

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
                        .id(manager.currentActivity)  // re-animate per change
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }
}

private struct AnimatedHeartLogo: View {
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
            // Pulsing inner glow
            Circle()
                .fill(.pink.opacity(0.18))
                .scaleEffect(pulse ? 0.95 : 0.7)
                .blur(radius: 12)
            // Heart symbol
            Image(systemName: "heart.fill")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.pink)
                .scaleEffect(pulse ? 1.08 : 1.0)
                .shadow(color: .pink.opacity(0.5), radius: pulse ? 12 : 6)
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
