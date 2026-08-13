import AppKit
import SwiftUI

/// Shared row used by the multi-meeting overlay styles: title, time, and the actions
/// that apply to *that* meeting. Kept deliberately small — when three of these are on
/// screen, each one has to be scannable in about a second.
struct ConcurrentMeetingRow: View {

    let meeting: MeetingEvent
    let compact: Bool
    /// Marks the top-ranked meeting (the one the ranking thinks you'll attend).
    var isLead: Bool = false
    let onJoin: (MeetingEvent) -> Void
    var onArm: ((MeetingEvent) -> Void)?

    @AppStorage("joinButtonEnabled") private var joinButtonEnabled: Bool = true
    @AppStorage("autoJoinEnabled") private var autoJoinEnabled: Bool = true

    private var canJoin: Bool { joinButtonEnabled && meeting.url != nil }
    private var canArm: Bool { canJoin && autoJoinEnabled && onArm != nil && meeting.timeUntilStart > 0 }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isLead ? Color(red: 0.25, green: 0.78, blue: 0.45) : .white.opacity(0.25))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: isLead ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.formattedStartTime)
                    if let response = meeting.myResponse.label {
                        Text("·")
                        Text(response)
                    }
                    if !canJoin {
                        Text("· no link")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            if canArm, let onArm {
                Button { onArm(meeting) } label: {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Open this meeting automatically when it starts")
            }

            if canJoin {
                Button { onJoin(meeting) } label: {
                    Text("Join")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.78, blue: 0.45)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 14 : 18)
        .padding(.vertical, compact ? 7 : 9)
    }
}

/// **Conflict panel** — one overlay owns the timeslot. A shared countdown ring for the
/// common start time, then a row per meeting. The clash itself is the headline, which is
/// the point: you're not being told "a meeting is starting", you're being told you're
/// double-booked and have to choose.
struct ConflictOverlayView: View {

    let meetings: [MeetingEvent]
    var compact: Bool = false
    let onDismiss: () -> Void
    let onJoin: (MeetingEvent) -> Void
    var onArm: ((MeetingEvent) -> Void)?

    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?

    private var start: Date { meetings.map(\.startDate).min() ?? Date() }
    private var hasStarted: Bool { timeRemaining < 0 }

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(compact ? 10 : 14)
                }

                VStack(spacing: compact ? 8 : 12) {
                    Text("\(meetings.count) MEETINGS AT \(timeLabel)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1.8)
                        .foregroundStyle(hasStarted ? .red.opacity(0.9) : .white.opacity(0.65))

                    ZStack {
                        Circle().stroke(lineWidth: compact ? 6 : 7).foregroundStyle(.white.opacity(0.15))
                        VStack(spacing: 2) {
                            Text(formattedTime)
                                .font(.system(size: compact ? 28 : 34, weight: .bold, design: .monospaced))
                                .foregroundStyle(hasStarted ? .red : .white)
                            Text(hasStarted ? "since start" : (timeRemaining > 60 ? "minutes" : "seconds"))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: compact ? 104 : 124, height: compact ? 104 : 124)
                }
                .padding(.bottom, compact ? 10 : 14)

                Divider().overlay(.white.opacity(0.14))

                VStack(spacing: 0) {
                    ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                        ConcurrentMeetingRow(meeting: meeting, compact: compact, isLead: index == 0,
                                             onJoin: onJoin, onArm: onArm)
                        if index < meetings.count - 1 {
                            Divider().overlay(.white.opacity(0.08)).padding(.leading, compact ? 30 : 36)
                        }
                    }
                }

                Divider().overlay(.white.opacity(0.14))

                Button(action: onDismiss) {
                    Text("Dismiss all")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 34 : 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.10))
            }
        }
        .onAppear {
            timeRemaining = start.timeIntervalSinceNow
            let t = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in timeRemaining = start.timeIntervalSinceNow }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        .onDisappear { timer?.invalidate() }
    }

    private var timeLabel: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: start)
    }

    private var formattedTime: String {
        let total = Int(abs(timeRemaining))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// **Card stack** — no big panel at all: one compact card per meeting, stacked in the
/// corner, each dismissable on its own. The only style that stays sane past three or
/// four simultaneous meetings.
struct ConflictCardStackView: View {

    let meetings: [MeetingEvent]
    var compact: Bool = false
    /// Dismiss one card; the controller closes the panel when the last one goes.
    let onDismissOne: (MeetingEvent) -> Void
    let onDismissAll: () -> Void
    let onJoin: (MeetingEvent) -> Void
    var onArm: ((MeetingEvent) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(meetings) { meeting in
                ConflictCard(meeting: meeting, compact: compact,
                             onDismiss: { onDismissOne(meeting) },
                             onJoin: { onJoin(meeting) },
                             onArm: onArm.map { arm in { arm(meeting) } })
            }
            if meetings.count > 1 {
                Button(action: onDismissAll) {
                    Text("Dismiss all")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .colorScheme(.dark)
    }
}

private struct ConflictCard: View {
    let meeting: MeetingEvent
    let compact: Bool
    let onDismiss: () -> Void
    let onJoin: () -> Void
    var onArm: (() -> Void)?

    @AppStorage("joinButtonEnabled") private var joinButtonEnabled: Bool = true
    @AppStorage("autoJoinEnabled") private var autoJoinEnabled: Bool = true
    @State private var now = Date()
    @State private var timer: Timer?

    private var canJoin: Bool { joinButtonEnabled && meeting.url != nil }
    private var canArm: Bool { canJoin && autoJoinEnabled && onArm != nil && meeting.startDate > now }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(countdownLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(meeting.startDate <= now ? .red : Color(red: 0.45, green: 0.80, blue: 1.0))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(meeting.formattedStartTime)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            Text(meeting.title)
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if canJoin {
                    Button(action: onJoin) {
                        Label("Join", systemImage: "video.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(Color(red: 0.25, green: 0.78, blue: 0.45)))
                    }
                    .buttonStyle(.plain)
                }
                if canArm, let onArm {
                    Button(action: onArm) {
                        Label("At start", systemImage: "clock.badge.checkmark")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                if !canJoin {
                    Text("No meeting link")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(12)
        .frame(width: compact ? 270 : 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1))
        )
        .onAppear {
            let t = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in now = Date() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        .onDisappear { timer?.invalidate() }
    }

    private var countdownLabel: String {
        let seconds = Int(meeting.startDate.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 60 { return "in \(seconds)s" }
        return "in \(seconds / 60)m"
    }
}
