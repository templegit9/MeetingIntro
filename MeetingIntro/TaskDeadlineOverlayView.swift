import SwiftUI

/// A small dark corner card shown when a task deadline reminder fires with the overlay
/// channel enabled (Issue #19). Non-blocking; Mark done or Dismiss.
struct TaskDeadlineOverlayView: View {
    let task: TaskItem
    let onDone: () -> Void
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.2))
            VStack(alignment: .leading, spacing: 2) {
                Text("Task due")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.6))
                Text(task.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !task.dueLabel.isEmpty {
                    Text(task.dueLabel).font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 5) {
                Button(action: onDone) {
                    Text("Done").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.78, blue: 0.45)))
                }
                .buttonStyle(.plain)
                Button(action: onSnooze) {
                    Text("Snooze 10m").font(.caption2).foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Text("Dismiss").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 380, height: 120)
        .colorScheme(.dark)
    }
}
