import SwiftUI

/// Persistent acknowledgment surface for cancelled meetings — NOT a toast.
///
/// Contract: if a meeting got cancelled while the user wasn't looking (overnight,
/// lid closed), this notice is waiting when they come back and stays until each
/// cancellation is explicitly dismissed. It renders the persisted
/// `pendingCancellations` state, so it survives sleep, wake, and app restarts.
/// There is deliberately NO auto-dismiss timer.
struct CancellationOverlayView: View {

    let items: [MeetingEvent]
    /// Called with the meeting ID when its Dismiss is clicked — feeds the same
    /// `dismissCancellation(id)` acknowledgment the dropdown badge uses.
    let onDismissItem: (String) -> Void

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.minus")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                    Text(items.count == 1 ? "MEETING CANCELLED" : "\(items.count) MEETINGS CANCELLED")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(items) { meeting in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(subtitle(for: meeting))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer(minLength: 10)
                                Button {
                                    onDismissItem(meeting.id)
                                } label: {
                                    Text("Dismiss")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(.white.opacity(0.18))
                                                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    .padding(.horizontal, 14)
                }

                Text("Stays here until dismissed — reminders for these meetings are already silenced.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 12)
            }
        }
    }

    private func subtitle(for meeting: MeetingEvent) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        let time = DateFormatter()
        time.timeStyle = .short
        var parts = ["was \(day.string(from: meeting.startDate)) \(time.string(from: meeting.startDate))"]
        if let organizer = meeting.organizerName, !organizer.isEmpty {
            parts.append("· \(organizer)")
        }
        return parts.joined(separator: " ")
    }
}
