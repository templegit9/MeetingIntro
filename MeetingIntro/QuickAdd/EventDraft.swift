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
}
