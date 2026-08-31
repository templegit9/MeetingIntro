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
}
