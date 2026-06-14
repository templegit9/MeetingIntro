import AppKit
import SwiftUI

/// A floating, always-on-top overlay that shows a countdown timer before a meeting.
struct CountdownOverlayView: View {

    let meeting: MeetingEvent
    let onDismiss: () -> Void
    /// Arms auto-join for this meeting (opens the link automatically at start time)
    /// and dismisses the overlay. Wired by `OverlayWindowController`.
    var onArmAutoJoin: (() -> Void)?

    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isAppearing = false
    @AppStorage("joinButtonEnabled") private var joinButtonEnabled: Bool = true
    @AppStorage("autoJoinEnabled") private var autoJoinEnabled: Bool = true
    @AppStorage("contextPanelMinThreshold") private var panelMinThreshold: Int = 0

    private var progress: Double {
        guard timeRemaining > 0 else { return 1.0 }
        let totalDuration = meeting.timeUntilStart + (meeting.startDate.timeIntervalSinceNow - timeRemaining)
        guard totalDuration > 0 else { return 1.0 }
        return 1.0 - (timeRemaining / totalDuration)
    }

    /// The meeting's start time has passed — we're in the negative-countdown phase,
    /// which runs until the user joins, dismisses, or the meeting ends.
    private var hasStarted: Bool { timeRemaining < 0 }

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
                    Text(hasStarted ? "MEETING IN PROGRESS" : "UPCOMING MEETING")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(2)
                        .foregroundStyle(hasStarted ? .red.opacity(0.9) : .white.opacity(0.6))

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

                    // Time display — turns red and counts negative once the meeting
                    // has started, until the user joins or dismisses.
                    VStack(spacing: 4) {
                        Text(formattedTime)
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundStyle(hasStarted ? .red : .white)

                        Text(hasStarted ? "since start" : (timeRemaining > 60 ? "minutes" : "seconds"))
                            .font(.caption)
                            .foregroundStyle(hasStarted ? .red.opacity(0.7) : .white.opacity(0.6))
                    }
                }
                .frame(width: 200, height: 200)

                // Pre-meeting details — notes, attendees, secondary join link.
                // Hidden when timeUntilStart is below the user-configured threshold
                // (default 0 = always show whenever there's content).
                if shouldShowDetailsPanel {
                    MeetingDetailsPanel(meeting: meeting)
                        .transition(.opacity)
                }

                // Start time info
                Text(hasStarted
                     ? "Started at \(meeting.formattedStartTime) — join or dismiss"
                     : "Starts at \(meeting.formattedStartTime)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))

                // Join button — visible when a conference link was detected
                if let joinURL = meeting.url, joinButtonEnabled {
                    Button {
                        // Joining IS the acknowledgment — close the overlay with it.
                        NSWorkspace.shared.open(joinURL)
                        onDismiss()
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

                // Start at Time — arms an auto-join. Only before start (afterward,
                // joining is immediate via the Join button) and only when there's a
                // link + the feature is on. Dismisses the overlay; the link opens
                // automatically when the meeting starts.
                if !hasStarted, meeting.url != nil, joinButtonEnabled, autoJoinEnabled,
                   let onArmAutoJoin {
                    Button(action: onArmAutoJoin) {
                        Label("Start at Time", systemImage: "clock.badge.checkmark")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .frame(minHeight: 40)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.18))
                                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open this meeting's link automatically when it starts")
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
            timeRemaining = meeting.startDate.timeIntervalSinceNow
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
                // Goes negative once the meeting starts — the overlay stays up,
                // counting time since start, until the user joins or dismisses.
                timeRemaining = meeting.startDate.timeIntervalSinceNow
                // Safety net: once the meeting has ENDED, joining is moot — close.
                if Date() >= meeting.endDate {
                    timer?.invalidate()
                    onDismiss()
                }
            }
        }
    }

    // MARK: - Details panel gating

    /// Computed once when the overlay appears — matches the logic the window controller
    /// uses to pick window size. Returns true iff the meeting is far enough out AND
    /// has at least one piece of content the panel can render.
    private var shouldShowDetailsPanel: Bool {
        Self.shouldShowDetailsPanel(for: meeting, threshold: panelMinThreshold)
    }

    static func shouldShowDetailsPanel(for meeting: MeetingEvent, threshold: Int) -> Bool {
        // 30-second grace so the panel doesn't snap shut as the timer crosses the threshold.
        guard meeting.timeUntilStart >= TimeInterval(threshold * 60) - 30 else { return false }
        let d = UserDefaults.standard
        let showNotes = d.object(forKey: "contextPanelShowNotes") as? Bool ?? true
        let showAttendees = d.object(forKey: "contextPanelShowAttendees") as? Bool ?? true
        let showJoinURL = d.object(forKey: "contextPanelShowJoinURL") as? Bool ?? true
        let hasNotes = showNotes && !(meeting.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttendees = showAttendees && !meeting.attendeeNames.isEmpty
        let hasJoinURL = showJoinURL && meeting.url != nil
        return hasNotes || hasAttendees || hasJoinURL
    }

    // MARK: - Formatting

    private var formattedTime: String {
        let totalSeconds = Int(timeRemaining.rounded())
        let prefix = totalSeconds < 0 ? "-" : ""
        let absSeconds = abs(totalSeconds)
        return String(format: "%@%02d:%02d", prefix, absSeconds / 60, absSeconds % 60)
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
