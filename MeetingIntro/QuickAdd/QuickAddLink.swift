import Foundation

/// A reusable meeting link the user can attach to events they create via Quick Add.
/// Stored in `QuickAddConfig.meetingLinks` (UserDefaults JSON). Not a credential —
/// a join URL is shareable by nature — so no Keychain.
struct SavedMeetingLink: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String          // "Personal Zoom"
    var url: String           // "https://zoom.us/j/1234567890"
    var isDefault: Bool = false
}

/// A reusable Quick Add template, invoked by typing `/<trigger>` as the first token
/// (e.g. `/standup tomorrow 9am`). Expands to a full event: the template supplies
/// title + duration + (optionally) a saved link and location; the rest of the typed
/// text supplies the date/time.
struct QuickAddTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: String          // "standup" — matched against the leading /token
    var title: String            // "Daily Standup"
    var durationMinutes: Int     // 15
    var linkID: UUID?            // which SavedMeetingLink to attach (nil = none)
    var location: String?
}

/// Decides whether a phrase describes a real-time meeting that warrants a join link.
/// Conservative by design: only attach the user's link when there's a positive
/// signal, so personal errands ("dentist tomorrow 3pm") never get stamped with a
/// Zoom link. The result is always surfaced in the preview (and toggleable), never
/// silent — consistent with the assumptions contract.
enum MeetingLinkHeuristic {

    /// Phrases that strongly imply a live meeting/call.
    private static let keywords: [String] = [
        "meeting", "meet ", "call", "sync", "1:1", "1-1", "one on one", "one-on-one",
        "standup", "stand-up", "stand up", "catch up", "catchup", "check in", "check-in",
        "chat", "huddle", "interview", "demo", "review", "session", "zoom", "teams",
        "google meet", "hangout", "webex", "conference", "kickoff", "kick-off", "kick off",
        "retro", "retrospective", "planning", "discussion", "debrief", "briefing", "standmeeting",
    ]

    static func isLikelyMeeting(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        if keywords.contains(where: { lower.contains($0) }) { return true }
        // "with <someone>" — a meeting with a person.
        if lower.range(of: #"\bwith\s+[a-z]"#, options: .regularExpression) != nil { return true }
        return false
    }
}

/// User's choice for whether/which link to attach, set from the preview controls.
/// `.auto` defers to the heuristic + default link (or a template's chosen link).
enum LinkChoice: Equatable {
    case auto
    case none
    case specific(UUID)
}

/// Expands a `/trigger …` input into the text to parse + the matched template.
enum TemplateExpander {

    /// Returns the text to feed the date parser and the matched template (if any).
    /// `"/standup tomorrow 9am"` with a "standup" template titled "Daily Standup"
    /// → ("Daily Standup tomorrow 9am", template).
    static func expand(_ input: String, templates: [QuickAddTemplate]) -> (text: String, template: QuickAddTemplate?) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return (input, nil) }

        // Leading /token (letters, digits, hyphen).
        let afterSlash = trimmed.dropFirst()
        let token = afterSlash.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !token.isEmpty else { return (input, nil) }

        guard let template = templates.first(where: {
            $0.trigger.compare(String(token), options: .caseInsensitive) == .orderedSame
        }) else { return (input, nil) }

        let remainder = afterSlash.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
        let text = remainder.isEmpty ? template.title : "\(template.title) \(remainder)"
        return (text, template)
    }

    /// Trigger suggestions for the typed-so-far `/frag` prefix (for the preview hint).
    static func matches(forPrefix input: String, templates: [QuickAddTemplate]) -> [QuickAddTemplate] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let frag = trimmed.dropFirst().lowercased()
        if frag.isEmpty { return templates }
        return templates.filter { $0.trigger.lowercased().hasPrefix(frag) }
    }
}
