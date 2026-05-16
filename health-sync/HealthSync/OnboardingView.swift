import SwiftUI

/// First-launch intro. Sets expectations *before* the iOS Health Access sheet
/// pops up with its 30-row toggle list. The big "Get started" button is what
/// actually triggers the HK auth request, so the user sees context immediately
/// before the OS-level prompt — not after, when they've already tapped through.
struct OnboardingView: View {
    /// Set to true to dismiss; persisted by ContentView.
    @Binding var done: Bool

    @EnvironmentObject var manager: HealthSyncManager
    @EnvironmentObject var notif: NotificationManager

    @State private var page = 0
    @State private var working = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.14, blue: 0.20),
                         Color(red: 0.05, green: 0.07, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack {
                TabView(selection: $page) {
                    welcomePage.tag(0)
                    permissionsPage.tag(1)
                    transportPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    Task { await advance() }
                } label: {
                    HStack {
                        Text(buttonLabel)
                            .font(.headline)
                        if working {
                            ProgressView().controlSize(.small).tint(.white)
                        } else if page < 2 {
                            Image(systemName: "arrow.right")
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(working)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .foregroundStyle(.white)
        }
    }

    private var buttonLabel: String {
        switch page {
        case 0:  return "Continue"
        case 1:  return "Grant access"
        default: return "Start syncing"
        }
    }

    /// Page 0 → Page 1 just animates forward. Page 1 → Page 2 actually fires
    /// the HK auth request (so the OS sheet shows now, with context fresh in
    /// the user's head, not later from a half-rendered Status tab). Page 2 →
    /// flip `done` and let ContentView take over.
    private func advance() async {
        switch page {
        case 0:
            withAnimation { page = 1 }
        case 1:
            working = true
            // Bootstrap pops the Apple HealthKit access sheet, installs the
            // observer queries, schedules BG refresh and kicks off the first
            // sync. It's marked idempotent on the manager so the eventual
            // ContentView `.task` below is a no-op.
            await manager.bootstrap()
            // Notification permission is cheap to ask for at the same time —
            // it's the only path that lets us fire a readiness-drop alert.
            await notif.requestAuth()
            notif.setAlertsEnabled(true)
            working = false
            withAnimation { page = 2 }
        default:
            done = true
        }
    }

    // MARK: pages

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Image("Mascot")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .shadow(color: .pink.opacity(0.4), radius: 16)
            Text("HealthSync")
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("Watch + iPhone health data, on your own server. No cloud, no resale, no marketing pixels.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .foregroundStyle(.white.opacity(0.85))
            FeatureBullet(symbol: "lock.shield.fill", text: "Encrypted in transit. Stored where you point it.")
            FeatureBullet(symbol: "battery.100", text: "Anchored deltas — only new samples, never the whole history twice.")
            FeatureBullet(symbol: "antenna.radiowaves.left.and.right", text: "HTTP or Pilot overlay — both fully offline-friendly.")
            Spacer()
        }
        .padding(.top, 40)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 56))
                .foregroundStyle(.pink)
                .frame(maxWidth: .infinity)
            Text("HealthKit access").font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            Text("The next screen is **Apple's Health Access sheet**. It lists every metric HealthSync can read — HRV, sleep, workouts, heart rate, energy, and so on.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
            Label {
                Text("Tap **Turn On All** at the top of that sheet. Anything you leave off won't sync.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checklist")
                    .foregroundStyle(.pink)
            }
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Label {
                Text("Notifications: we'll only alert you when readiness drops sharply or sync stops. No daily nags.")
                    .font(.callout)
            } icon: {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.pink)
            }
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var transportPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 56))
                .foregroundStyle(.pink)
                .frame(maxWidth: .infinity)
            Text("Where should your data go?")
                .font(.title.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("You can switch any time in **Settings → Transport**. The default is HTTP to a local server you control.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))

            Picker("", selection: Binding(
                get: { manager.transportKind },
                set: { manager.updateTransport($0) }
            )) {
                Label(TransportKind.http.displayName, systemImage: TransportKind.http.symbol)
                    .tag(TransportKind.http)
                Label(TransportKind.pilot.displayName, systemImage: TransportKind.pilot.symbol)
                    .tag(TransportKind.pilot)
            }
            .pickerStyle(.segmented)
            .colorScheme(.dark)

            Text(transportBlurb)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var transportBlurb: String {
        switch manager.transportKind {
        case .http:
            return "HTTP: point HealthSync at any host running the ingest endpoint. Point it at a homelab, a Raspberry Pi, or your laptop — anywhere on your network."
        case .pilot:
            return "Pilot: routes through the overlay network so HealthSync reaches your homelab from anywhere without VPNs or port-forwarding. You'll wire up the peer address in Settings → Transport → Pilot."
        }
    }
}

private struct FeatureBullet: View {
    let symbol: String
    let text:   String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.pink)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}
