import AppKit
import SwiftUI

/// A floating, always-on-top overlay that shows a countdown timer before a meeting.
struct CountdownOverlayView: View {

    let meeting: MeetingEvent
    /// Tighter layout (smaller ring/type, less spacing) used when the roomy overlay
    /// wouldn't fit the screen — or when the user forces it via
    /// `CountdownConfig.overlayCompactLayout`. Set by `OverlayWindowController`, which
    /// sizes the panel to match.
    var compact: Bool = false
    let onDismiss: () -> Void
    /// Arms auto-join for this meeting (opens the link automatically at start time)
    /// and dismisses the overlay. Wired by `OverlayWindowController`.
    var onArmAutoJoin: (() -> Void)?
    /// Stop all future reminders for this event (Issue #15) and dismiss. Wired by
    /// `OverlayWindowController`.
    var onDismissFutureReminders: (() -> Void)?

    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isAppearing = false
    /// Shows the "Armed ✓" confirmation briefly before the overlay closes, so the
    /// Start-at-Time tap visibly registers instead of the window just vanishing.
    @State private var armedConfirmation = false
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

    /// Best-effort link when `meeting.url` is nil: the first http(s) link anywhere in
    /// the notes/location. Catches join links from providers the structured extractor
    /// doesn't recognize, so the overlay still offers an action (Issue #9).
    private var fallbackJoinURL: URL? {
        let text = [meeting.notes, meeting.location].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, url.scheme == "http" || url.scheme == "https" { return url }
        }
        return nil
    }

    // MARK: - Layout metrics
    //
    // Everything that scales between the roomy and compact layouts lives here so the
    // two stay in proportion. `OverlayWindowController` picks the panel size from the
    // same `compact` flag.
    private var stackSpacing: CGFloat { compact ? 12 : 18 }
    private var ringSize: CGFloat { compact ? 124 : 176 }
    private var ringLineWidth: CGFloat { compact ? 6 : 8 }
    private var timeFontSize: CGFloat { compact ? 32 : 44 }
    private var titleFontSize: CGFloat { compact ? 20 : 26 }
    private var closeButtonPadding: CGFloat { compact ? 10 : 14 }
    private var titleHorizontalPadding: CGFloat { compact ? 24 : 40 }
    private var bottomInset: CGFloat { compact ? 12 : 20 }

    /// Height the content needs at `width` — `OverlayWindowController` sizes the panel
    /// from this (clamped to the screen) instead of the old fixed 560/720pt, which both
    /// over-filled small displays and left the lower buttons off the panel on busy
    /// meetings. Builds a throwaway hosting view; called once per overlay show.
    @MainActor
    func contentFittingHeight(width: CGFloat) -> CGFloat {
        let probe = NSHostingView(rootView: content.frame(width: width))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize.height
    }

    var body: some View {
        ZStack {
            // Background blur/glass
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Header and actions are fixed; only the info area between them scrolls.
            // The panel is sized to fit the whole thing (see `contentFittingHeight`), so
            // this only ever engages when the screen clamp bites — and when it does, the
            // Join/Dismiss buttons are still on screen instead of clipped off the bottom.
            VStack(spacing: 0) {
                header
                ScrollView(.vertical) {
                    infoSection
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                actionSection
            }

            // Armed confirmation — covers the content (and the other buttons, so a
            // stray tap can't race the arm) until the overlay closes.
            if armedConfirmation {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: compact ? 44 : 60))
                            .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.45))
                        Text("Armed")
                            .font(.system(size: compact ? 22 : 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Label("Counting down in the menu bar", systemImage: "arrow.up.right")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .transition(.opacity)
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

    /// Non-scrolling composition of every section — what the panel would need if it
    /// had unlimited room. `contentFittingHeight` measures this; the live `body` splits
    /// it into a scrollable info area with the actions pinned below.
    private var content: some View {
        VStack(spacing: 0) {
            header
            infoSection
            actionSection
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .padding(closeButtonPadding)
        }
    }

    /// Title, countdown ring, details panel, start-time line. This is the part that
    /// scrolls when the panel is clamped to the screen — the actions never do.
    private var infoSection: some View {
        VStack(spacing: stackSpacing) {
            // Meeting Title
            VStack(spacing: 8) {
                Text(hasStarted ? "MEETING IN PROGRESS" : "UPCOMING MEETING")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(2)
                    .foregroundStyle(hasStarted ? .red.opacity(0.9) : .white.opacity(0.6))

                Text(meeting.title)
                    .font(.system(size: titleFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, titleHorizontalPadding)

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
                    .stroke(lineWidth: ringLineWidth)
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
                        style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1), value: progress)

                // Time display — turns red and counts negative once the meeting
                // has started, until the user joins or dismisses.
                VStack(spacing: 4) {
                    Text(formattedTime)
                        .font(.system(size: timeFontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(hasStarted ? .red : .white)

                    Text(hasStarted ? "since start" : (timeRemaining > 60 ? "minutes" : "seconds"))
                        .font(.caption)
                        .foregroundStyle(hasStarted ? .red.opacity(0.7) : .white.opacity(0.6))
                }
            }
            .frame(width: ringSize, height: ringSize)

            // Pre-meeting details — notes, attendees, secondary join link.
            // Hidden when timeUntilStart is below the user-configured threshold
            // (default 0 = always show whenever there's content).
            if shouldShowDetailsPanel {
                MeetingDetailsPanel(meeting: meeting, compact: compact)
                    .transition(.opacity)
            }

            // Start time info
            Text(hasStarted
                 ? "Started at \(meeting.formattedStartTime) — join or dismiss"
                 : "Starts at \(meeting.formattedStartTime)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, stackSpacing)
    }

    /// Join / Start at Time / Dismiss. Pinned outside the scroll area so the overlay
    /// always offers an action, however little room the screen has.
    private var actionSection: some View {
        VStack(spacing: compact ? 8 : 12) {
            // Join button — the detected conference link, or a best-effort fallback
            // link found in the notes/location when no structured link was extracted
            // (Issue #9: an unrecognized/corporate join link left the overlay with no
            // action at all, stranding the user after start).
            if joinButtonEnabled, let actionURL = meeting.url ?? fallbackJoinURL {
                Button {
                    // Joining IS the acknowledgment — close the overlay with it.
                    NSWorkspace.shared.open(actionURL)
                    onDismiss()
                } label: {
                    Label(meeting.url != nil ? "Join Meeting" : "Open Meeting Link", systemImage: "video.fill")
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
            } else if joinButtonEnabled {
                // No link anywhere — give the user a way out instead of a dead end.
                Button {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                    onDismiss()
                } label: {
                    Label("Open in Calendar", systemImage: "calendar")
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
                .help("No meeting link was found — open Calendar to join from there")
            }

            // Secondary actions share a row so the overlay stays short.
            HStack(spacing: 10) {
                // Start at Time — arms an auto-join. Only before start (afterward,
                // joining is immediate via the Join button) and only when there's a
                // link + the feature is on. Dismisses the overlay; the link opens
                // automatically when the meeting starts.
                if !hasStarted, meeting.url != nil, joinButtonEnabled, autoJoinEnabled,
                   let onArmAutoJoin {
                    Button {
                        // Acknowledge the tap, then arm + dismiss after a beat. The
                        // confirmation overlay covers the other buttons so a stray
                        // Dismiss tap can't race the arm.
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            armedConfirmation = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            onArmAutoJoin()
                        }
                    } label: {
                        Label("Start at Time", systemImage: "clock.badge.checkmark")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .frame(minHeight: 38)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.18))
                                    .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open this meeting's link automatically when it starts")
                }

                // Dismiss button
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .frame(minHeight: 38)
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
            }

            // Stop all future reminders for this event (Issue #15).
            if let onDismissFutureReminders {
                Button(action: onDismissFutureReminders) {
                    Label("Don't remind me again for this", systemImage: "bell.slash")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Skip the remaining reminders for this meeting")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, bottomInset)
    }

    // MARK: - Timer

    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                // Goes negative once the meeting starts — the overlay stays up,
                // counting time since start, until the user joins or dismisses.
                timeRemaining = meeting.startDate.timeIntervalSinceNow
                // Safety net: close once the meeting has ENDED, OR once it's been in
                // progress past the configured cap — so a long meeting (or a far-off
                // end) can't pin the overlay indefinitely (a real report had one up
                // ~12h). Mirrors CalendarManager's poll-side cap.
                let capMin = UserDefaults.standard.object(forKey: "inProgressOverlayMaxMinutes") as? Int ?? 15
                let secondsSinceStart = -meeting.startDate.timeIntervalSinceNow
                let cappedInProgress = capMin > 0 && secondsSinceStart >= TimeInterval(capMin * 60)
                if Date() >= meeting.endDate || cappedInProgress {
                    timer?.invalidate()
                    onDismiss()
                }
            }
        }
        // Schedule in `.common` so the countdown keeps firing during menu / event
        // tracking and doesn't stall — a stalled timer left the overlay frozen and
        // unresponsive after a long stretch (the "won't respond to input" symptom).
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
