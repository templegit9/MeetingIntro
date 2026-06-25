import Foundation
import SwiftUI

/// The kind of conferencing service a saved link points at. Drives the row icon/tint
/// and the starter name in the add form. Detected from the URL when not explicitly set
/// (so links saved before this field existed still get an icon).
enum MeetingLinkProvider: String, Codable, CaseIterable, Identifiable {
    case zoom, meet, teams, webex, phone, other

    var id: String { rawValue }

    /// Label shown in the Type picker.
    var displayName: String {
        switch self {
        case .zoom:  return "Zoom"
        case .meet:  return "Google Meet"
        case .teams: return "Teams"
        case .webex: return "Webex"
        case .phone: return "Phone"
        case .other: return "Other"
        }
    }

    /// Starter name pre-filled when the user picks this type in the add form.
    var defaultName: String {
        switch self {
        case .zoom:  return "Zoom"
        case .meet:  return "Google Meet"
        case .teams: return "Teams"
        case .webex: return "Webex"
        case .phone: return "Phone Bridge"
        case .other: return ""
        }
    }

    /// SF Symbol for the row glyph.
    var sfSymbol: String {
        switch self {
        case .zoom:  return "video.fill"
        case .meet:  return "video.fill"
        case .teams: return "person.2.fill"
        case .webex: return "video.fill"
        case .phone: return "phone.fill"
        case .other: return "link"
        }
    }

    /// Tint so providers are scannable at a glance.
    var tint: Color {
        switch self {
        case .zoom:  return Color(red: 0.18, green: 0.45, blue: 0.95) // Zoom blue
        case .meet:  return Color(red: 0.0,  green: 0.66, blue: 0.42) // Meet green
        case .teams: return Color(red: 0.36, green: 0.36, blue: 0.78) // Teams purple
        case .webex: return Color(red: 0.0,  green: 0.6,  blue: 0.6)  // Webex teal
        case .phone: return Color(red: 0.4,  green: 0.75, blue: 0.3)
        case .other: return .secondary
        }
    }

    /// Best-effort provider detection from a join URL / phone string.
    static func detect(from raw: String) -> MeetingLinkProvider {
        let s = raw.lowercased()
        if s.hasPrefix("tel:") || s.range(of: #"^\+?[0-9][0-9\s().-]{6,}$"#, options: .regularExpression) != nil {
            return .phone
        }
        if s.contains("zoom.us") || s.contains("zoom.com") { return .zoom }
        if s.contains("meet.google") { return .meet }
        if s.contains("teams.microsoft") || s.contains("teams.live") { return .teams }
        if s.contains("webex.com") { return .webex }
        return .other
    }
}

/// A reusable meeting link the user can attach to events they create via Quick Add.
/// Stored in `QuickAddConfig.meetingLinks` (UserDefaults JSON). Not a credential —
/// a join URL is shareable by nature — so no Keychain.
struct SavedMeetingLink: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String          // "Personal Zoom"
    var url: String           // "https://zoom.us/j/1234567890"
    var isDefault: Bool = false
    /// Explicit provider chosen in the add form. Optional so links persisted before
    /// this field existed still decode; `resolvedProvider` falls back to URL detection.
    var provider: MeetingLinkProvider?

    /// Provider for the row glyph — the stored choice, else detected from the URL.
    var resolvedProvider: MeetingLinkProvider {
        provider ?? MeetingLinkProvider.detect(from: url)
    }
}

/// Validates + normalizes a meeting-link URL typed in Settings. Accepts http(s) URLs
/// and `tel:` / bare phone numbers (normalized to `tel:`). Returns nil with a reason
/// when the input can't be a usable join target.
enum MeetingLinkValidator {
    static func normalize(_ raw: String) -> (url: String?, error: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Enter a URL or phone number.") }

        // Phone: tel: or a bare number → normalize to tel:
        if trimmed.lowercased().hasPrefix("tel:") {
            return (trimmed, nil)
        }
        if trimmed.range(of: #"^\+?[0-9][0-9\s().-]{6,}$"#, options: .regularExpression) != nil {
            let digits = trimmed.filter { $0.isNumber || $0 == "+" }
            return ("tel:\(digits)", nil)
        }

        // URL: require an http(s) scheme + a dotted host. Prepend https:// to a bare domain.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let comps = URLComponents(string: candidate),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, host.contains(".") else {
            return (nil, "That doesn't look like a valid link or phone number.")
        }
        return (candidate, nil)
    }
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
