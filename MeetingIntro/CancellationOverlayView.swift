import SwiftUI

/// A compact floating notice shown when a meeting is cancelled — same visual family
/// as `CountdownOverlayView` (dark blur panel, always-on-top NSPanel) but smaller
/// and self-dismissing. Gated behind the off-by-default
/// `cancellationShowOverlay` setting.
struct CancellationOverlayView: View {

    let meeting: MeetingEvent
    let onDismiss: () -> Void

    /// Auto-dismiss after this many seconds; the user can also dismiss manually.
    static let autoDismissAfter: TimeInterval = 12

    @State private var isAppearing = false

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.minus")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)

                VStack(spacing: 6) {
                    Text("MEETING CANCELLED")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.6))

                    Text(meeting.title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.2))
                                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 24)
        }
        .opacity(isAppearing ? 1 : 0)
        .scaleEffect(isAppearing ? 1 : 0.95)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { isAppearing = true }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissAfter * 1_000_000_000))
                onDismiss()
            }
        }
    }

    private var subtitle: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        var parts = ["was \(formatter.string(from: meeting.startDate))"]
        if let organizer = meeting.organizerName, !organizer.isEmpty {
            parts.append("· \(organizer)")
        }
        return parts.joined(separator: " ")
    }
}
