import Foundation

/// A parsed-but-not-yet-created calendar event — the intermediate between the
/// Quick Add text input and an EventKit write. Carries which parser produced it
/// so the preview can hint "on-device" vs "via <model>".
struct EventDraft: Equatable {
    enum Parser: Equatable {
        case detector
        case llm(model: String)

        var displayName: String {
            switch self {
            case .detector: return "parsed on-device"
            case .llm(let model): return "via \(model)"
            }
        }
    }

    /// Whether this draft creates a calendar event or a task (Issue #19). Auto-detected
    /// from the text (`TaskIntentHeuristic`), overridable in the preview.
    var kind: DraftKind = .event
    var title: String
    var startDate: Date
    var endDate: Date
    var location: String?
    var notes: String?
    var parserUsed: Parser
    /// Human-readable assumptions the parser had to make for missing info
    /// ("No start time given — assumed 9:00 AM"). Surfaced as warnings in the
    /// preview so a silent guess never lands on the calendar unnoticed.
    var assumptions: [String] = []
    /// Join link attached to the event (from a saved meeting link, or one parsed
    /// out of the text). Written to `EKEvent.url`, so the overlay Join button,
    /// audio handoff, and auto-record all pick it up for self-created meetings.
    var url: String? = nil
    /// Email addresses to invite. **Only Microsoft 365 can act on these** — EventKit
    /// offers no API to add attendees or send invitations, which is the whole reason
    /// creating in Graph exists. Written events carry them; EventKit writes ignore them
    /// and the preview says so rather than silently dropping people.
    var attendees: [String] = []
    /// Display name of the saved link that was attached, if any — shown as an
    /// informational row in the preview (distinct from the orange assumptions).
    var attachedLinkName: String? = nil
    /// All-day event. The dates are still real dates (midnight to midnight); this is
    /// what tells the backends to store it as all-day rather than a 24-hour block.
    var isAllDay: Bool = false
    /// Repeat pattern, or nil for a one-off. Written to both backends — see
    /// `DraftRecurrence` for why the set is small.
    var recurrence: DraftRecurrence? = nil
}

// MARK: - Recurrence

/// How an event repeats. Deliberately a small, closed set of the patterns people
/// actually pick from a menu — anything richer belongs in Calendar.app, and offering a
/// control we can't write to both backends would be a promise we can't keep.
///
/// Every case is expressible in **both** EventKit (`EKRecurrenceRule`) and Graph
/// (`recurrence.pattern`), which is the constraint that decides the set: an event
/// created in Outlook must repeat exactly as one created in macOS Calendar.
enum DraftRecurrence: Equatable, Hashable, Identifiable {
    case daily
    /// 1 = Sunday … 7 = Saturday, matching `Calendar.component(.weekday,…)`.
    case weekly(weekday: Int)
    case monthly(day: Int)
    case yearly(month: Int, day: Int)

    var id: String {
        switch self {
        case .daily: return "daily"
        case .weekly(let w): return "weekly-\(w)"
        case .monthly(let d): return "monthly-\(d)"
        case .yearly(let m, let d): return "yearly-\(m)-\(d)"
        }
    }

    /// The options offered for a given start date, "Never" first.
    static func options(for date: Date, calendar: Calendar = .current) -> [DraftRecurrence?] {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        return [nil,
                .daily,
                .weekly(weekday: parts.weekday ?? 2),
                .monthly(day: parts.day ?? 1),
                .yearly(month: parts.month ?? 1, day: parts.day ?? 1)]
    }

    func label(calendar: Calendar = .current) -> String {
        let symbols = calendar.weekdaySymbols
        let months = calendar.monthSymbols
        switch self {
        case .daily:
            return "Daily"
        case .weekly(let weekday):
            let name = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "that day"
            return "Weekly on \(name)"
        case .monthly(let day):
            return "Monthly on the \(Self.ordinal(day))"
        case .yearly(let month, let day):
            let name = months.indices.contains(month - 1) ? months[month - 1] : ""
            return "Yearly on \(name) \(day)"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
