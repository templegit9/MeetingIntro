import Foundation

/// Extracts a canonical "join meeting" URL from event fields.
///
/// Lookup priority:
///   1. `graphOnlineMeetingURL` (Microsoft Graph's structured `onlineMeeting.joinUrl`)
///   2. `eventURL` (EventKit's `EKEvent.url` field)
///   3. Regex scan of `notes`
///   4. Regex scan of `location`
///
/// Structured fields beat regex scraping. Regex only kicks in when the calendar
/// system didn't populate a structured link (typical for Zoom invites pasted
/// into a Google Calendar event description).
enum ConferenceLinkExtractor {

    /// Choose the best join URL from the available signals.
    static func bestURL(
        eventURL: URL?,
        notes: String?,
        location: String?,
        graphOnlineMeetingURL: URL? = nil
    ) -> URL? {
        if let url = graphOnlineMeetingURL { return url }
        if let url = eventURL, isLikelyConferenceURL(url) { return url }
        if let notes, let match = firstMatch(in: notes) { return match }
        if let location, let match = firstMatch(in: location) { return match }
        return nil
    }

    private static let patterns: [String] = [
        // Zoom
        #"https://[a-z0-9.-]*zoom\.us/(j|my|s|w)/[A-Za-z0-9?=&._%-]+"#,
        // Microsoft Teams (work + personal)
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s"<>]+"#,
        #"https://teams\.live\.com/meet/[^\s"<>]+"#,
        // Google Meet (3-3-3 or 4-4-4 letter codes, optional query)
        #"https://meet\.google\.com/[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}(\?[^\s"<>]*)?"#,
        // Webex
        #"https://[a-z0-9.-]*webex\.com/(meet|join|wbxmjs)/[^\s"<>]+"#,
        // GoToMeeting
        #"https://(app\.)?gotomeeting\.com/(join|meeting)/\d+"#,
        #"https://global\.gotomeeting\.com/join/\d+"#,
    ]

    private static let combinedRegex: NSRegularExpression = {
        let combined = patterns.map { "(?:\($0))" }.joined(separator: "|")
        return try! NSRegularExpression(pattern: combined, options: [.caseInsensitive])
    }()

    private static func firstMatch(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = combinedRegex.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text)
        else { return nil }
        return URL(string: String(text[swiftRange]))
    }

    private static func isLikelyConferenceURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("zoom.us")
            || host.contains("teams.microsoft.com")
            || host.contains("teams.live.com")
            || host.contains("meet.google.com")
            || host.contains("webex.com")
            || host.contains("gotomeeting.com")
    }
}
