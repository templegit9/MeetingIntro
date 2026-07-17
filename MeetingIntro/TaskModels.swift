import Foundation

/// A lightweight todo with an optional deadline (Issue #19). Fires a reminder through
/// the same channels as meeting reminders (overlay / notification / voice). Stored either
/// in-app (JSON) or in Apple Reminders, behind the `TaskStore` protocol.
struct TaskItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var title: String
    var notes: String? = nil
    var dueDate: Date? = nil
    var isCompleted: Bool = false
    /// Minutes before `dueDate` to fire the reminder (0 = at the due time).
    var remindLeadMinutes: Int = 0
    /// Which channels the deadline reminder uses. Default is the "gentle" one:
    /// system notification only.
    var showOverlay: Bool = false
    var sendNotification: Bool = true
    var playVoice: Bool = false

    /// The moment the reminder should fire (`dueDate - lead`), or nil if no due date.
    var remindAt: Date? {
        guard let dueDate else { return nil }
        return dueDate.addingTimeInterval(-TimeInterval(remindLeadMinutes * 60))
    }

    var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < Date()
    }

    /// Short human due label ("Today 5:00 PM", "Fri 5:00 PM", "Jun 5"), or "" if none.
    var dueLabel: String {
        guard let dueDate else { return "" }
        let cal = Calendar.current
        let time = DateFormatter.taskTime.string(from: dueDate)
        if cal.isDateInToday(dueDate)    { return "Today \(time)" }
        if cal.isDateInTomorrow(dueDate) { return "Tomorrow \(time)" }
        if let days = cal.dateComponents([.day], from: Date(), to: dueDate).day, days >= 0, days < 7 {
            return "\(DateFormatter.taskWeekday.string(from: dueDate)) \(time)"
        }
        return "\(DateFormatter.taskDate.string(from: dueDate)) \(time)"
    }
}

private extension DateFormatter {
    static let taskTime: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    static let taskWeekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    static let taskDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
}

/// Whether a Quick Add draft is being created as a calendar event or a task.
enum DraftKind: String, Codable, Equatable {
    case event, task
}

/// Decides whether typed text reads like a task (todo) rather than a calendar event.
/// Conservative + always surfaced with a toggle in the preview, so a misclassification
/// is never silent.
enum TaskIntentHeuristic {
    /// Explicit task prefixes.
    private static let prefixes = ["todo:", "todo ", "task:", "task ", "remind me to ", "remember to "]
    /// Deadline words that imply a due date rather than a meeting start.
    private static let deadlineWords = [" by ", " due ", " deadline", " before "]

    static func isTask(_ text: String) -> Bool {
        let lower = " " + text.lowercased()
        if prefixes.contains(where: { lower.contains($0) }) { return true }
        // A deadline phrase with no meeting-like signal reads as a task.
        if deadlineWords.contains(where: { lower.contains($0) }),
           !MeetingLinkHeuristic.isLikelyMeeting(text) {
            return true
        }
        return false
    }
}
