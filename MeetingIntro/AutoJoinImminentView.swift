import AppKit
import SwiftUI

/// A small, non-blocking heads-up shown shortly before an armed ("Start at Time")
/// meeting auto-joins. It does NOT block — it just reassures the user the meeting is
/// about to open, with a live countdown and a last-second Cancel / Join now. The
/// overlay is dismissed automatically when the meeting opens (the armed set empties).
struct AutoJoinImminentView: View {
    let meeting: MeetingEvent
    let onCancel: () -> Void
    let onJoinNow: () -> Void

    @State private var remaining: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 26))
                .foregroundStyle(Color(red: 0.4, green: 0.8, blue: 1.0))

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Joining automatically in \(MenuBarCountdownModel.format(max(0, remaining)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button(action: onJoinNow) {
                    Text("Join now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.78, blue: 0.45)))
                }
                .buttonStyle(.plain)
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            remaining = meeting.startDate.timeIntervalSinceNow
            let t = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in remaining = meeting.startDate.timeIntervalSinceNow }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        .onDisappear { timer?.invalidate() }
    }
}
