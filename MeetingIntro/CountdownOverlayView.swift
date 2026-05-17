import AppKit
import SwiftUI

/// A floating, always-on-top overlay that shows a countdown timer before a meeting.
struct CountdownOverlayView: View {

    let meeting: MeetingEvent
    let onDismiss: () -> Void

    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isAppearing = false
    @AppStorage("joinButtonEnabled") private var joinButtonEnabled: Bool = true

    private var progress: Double {
        guard timeRemaining > 0 else { return 1.0 }
        let totalDuration = meeting.timeUntilStart + (meeting.startDate.timeIntervalSinceNow - timeRemaining)
        guard totalDuration > 0 else { return 1.0 }
        return 1.0 - (timeRemaining / totalDuration)
    }

    var body: some View {
        ZStack {
            // Background blur/glass
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Content
            VStack(spacing: 24) {
                // Header
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }

                Spacer()

                // Meeting Title
                VStack(spacing: 8) {
                    Text("UPCOMING MEETING")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.6))

                    Text(meeting.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 40)

                    if let location = meeting.location, !location.isEmpty {
                        Label(location, systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                // Countdown Ring
                ZStack {
                    // Background ring
                    Circle()
                        .stroke(lineWidth: 8)
                        .foregroundStyle(.white.opacity(0.15))

                    // Progress ring
                    Circle()
                        .trim(from: 0, to: min(progress, 1.0))
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.4, green: 0.8, blue: 1.0),
                                    Color(red: 0.6, green: 0.4, blue: 1.0),
                                    Color(red: 1.0, green: 0.4, blue: 0.6),
                                    Color(red: 0.4, green: 0.8, blue: 1.0)
                                ]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 1), value: progress)

                    // Time display
                    VStack(spacing: 4) {
                        Text(formattedTime)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)

                        Text(timeRemaining > 60 ? "minutes" : "seconds")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 200, height: 200)

                // Start time info
                Text("Starts at \(meeting.formattedStartTime)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))

                // Join button — visible when a conference link was detected
                if let joinURL = meeting.url, joinButtonEnabled {
                    Button {
                        NSWorkspace.shared.open(joinURL)
                    } label: {
                        Label("Join Meeting", systemImage: "video.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .frame(minHeight: 44)
                            .background(
                                Capsule()
                                    .fill(Color(red: 0.25, green: 0.78, blue: 0.45))
                                    .shadow(color: Color.black.opacity(0.25), radius: 6, y: 3)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Dismiss button
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.2))
                                .overlay(
                                    Capsule()
                                        .stroke(.white.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
        }
        .opacity(isAppearing ? 1 : 0)
        .scaleEffect(isAppearing ? 1 : 0.95)
        .onAppear {
            timeRemaining = max(0, meeting.startDate.timeIntervalSinceNow)
            startTimer()
            withAnimation(.easeOut(duration: 0.5)) {
                isAppearing = true
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                timeRemaining = max(0, meeting.startDate.timeIntervalSinceNow)
                if timeRemaining <= 0 {
                    timer?.invalidate()
                    // Auto-dismiss after a brief delay
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Formatting

    private var formattedTime: String {
        let totalSeconds = Int(timeRemaining)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Visual Effect Blur (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
