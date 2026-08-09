import Foundation
import SwiftUI

/// One cell in the crawl: a glyph, a line of text, and a tint.
struct TickerItem: Identifiable, Equatable {
    let id: String
    let symbol: String
    let text: String
    let tint: TickerTint

    /// Semantic colours, resolved in the view. Kept as an enum (not `Color`) so items
    /// stay `Equatable` and cheap to diff between rebuilds.
    enum TickerTint: Equatable {
        case neutral, accent, warning, alert, success
    }
}

/// Builds the ticker feed from live app state. Pure input → output: no side effects, no
/// stored state, so what shows in the strip is entirely a function of the calendar, the
/// task list, and the user's source selection.
enum TickerFeed {

    /// Assemble the feed, most urgent first.
    @MainActor
    static func build(
        meetings: [MeetingEvent],
        cancellations: [MeetingEvent],
        armed: [MeetingEvent],
        tasks: [TaskItem],
        isRecording: Bool,
        recordingTitle: String?,
        config: TickerConfig,
        now: Date = Date()
    ) -> [TickerItem] {
        var items: [TickerItem] = []

        if config.showCancellations {
            for meeting in cancellations {
                items.append(TickerItem(id: "cancel_\(meeting.id)",
                                        symbol: "xmark.circle.fill",
                                        text: "Cancelled — \(meeting.title)",
                                        tint: .alert))
            }
        }

        if config.showTasks {
            let horizon = now.addingTimeInterval(TimeInterval(config.taskLookaheadHours * 3600))
            let due = tasks
                .filter { !$0.isCompleted }
                .filter { task in
                    guard let dueDate = task.dueDate else { return false }
                    return dueDate <= horizon
                }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            for task in due {
                let overdue = task.isOverdue
                items.append(TickerItem(id: "task_\(task.id)",
                                        symbol: overdue ? "exclamationmark.circle.fill" : "checkmark.circle",
                                        text: overdue
                                            ? "Overdue — \(task.title) (\(task.dueLabel))"
                                            : "Task — \(task.title) · \(task.dueLabel)",
                                        tint: overdue ? .warning : .neutral))
            }
        }

        if config.showMeetings {
            let upcoming = meetings
                .filter { !$0.isCancelled && $0.endDate > now }
                .sorted { $0.startDate < $1.startDate }
            for meeting in upcoming {
                let starts = meeting.startDate.timeIntervalSince(now)
                let when: String
                if starts <= 0 {
                    when = "in progress"
                } else {
                    when = "in \(relative(starts))"
                }
                items.append(TickerItem(id: "meeting_\(meeting.id)",
                                        symbol: starts <= 0 ? "record.circle" : "calendar",
                                        text: "\(meeting.title) — \(when) (\(meeting.formattedStartTime))",
                                        tint: starts > 0 && starts <= 15 * 60 ? .accent : .neutral))
            }
        }

        if config.showStatus {
            if isRecording {
                items.append(TickerItem(id: "status_recording",
                                        symbol: "record.circle.fill",
                                        text: "Recording — \(recordingTitle ?? "meeting")",
                                        tint: .alert))
            }
            for meeting in armed {
                items.append(TickerItem(id: "status_armed_\(meeting.id)",
                                        symbol: "clock.badge.checkmark",
                                        text: "Auto-join armed — \(meeting.title) at \(meeting.formattedStartTime)",
                                        tint: .success))
            }
        }

        return items
    }

    /// "45s" / "12m" / "3h 5m" — short enough to read in a moving strip.
    private static func relative(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1))s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
