import Foundation

// MARK: - RSVP / response status

/// The current user's RSVP to a meeting invitation (or everyone's, when tallying).
/// `.organizer` = you created/own it; `.unknown` = no invitee/response data at all
/// (a plain personal event, a self-created block, or a backend that didn't report it).
/// Both `.organizer` and `.unknown` are treated as "always remind" — the response
/// gate only ever suppresses genuine invitations you declined / didn't answer.
enum ResponseStatus: String, Equatable {
    case accepted
    case declined
    case tentative
    case noResponse
    case organizer
    case unknown
}

/// Tally of attendee responses for the pre-meeting details panel ("5 accepted · 1
/// declined · 2 no reply"). nil when the event carries no attendee response data.
struct ResponseCounts: Equatable {
    var accepted = 0
    var declined = 0
    var tentative = 0
    var noResponse = 0

    var total: Int { accepted + declined + tentative + noResponse }
}

// MARK: - MeetingEvent Model

/// A unified meeting event model used across all calendar providers.
struct MeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarName: String
    let location: String?
    let isAllDay: Bool
    let url: URL?
    let notes: String?
    let attendeeNames: [String]
    let attendeeCount: Int
    let organizerName: String?
    let isCancelled: Bool
    /// Whether this event is part of a recurring series. EventKit gives every occurrence
    /// the SAME id, so an id-keyed baseline can't tell a real reschedule from the series
    /// advancing to the next occurrence — time-change detection therefore keys recurring
    /// events by `occurrenceDate` instead. Defaults false so existing construction stays valid.
    var isRecurring: Bool = false
    /// For a recurring occurrence, the date it was ORIGINALLY scheduled to occur
    /// (EventKit `EKEvent.occurrenceDate`). Stays fixed even when the occurrence is
    /// moved, so `startDate != occurrenceDate` means the occurrence was rescheduled.
    /// This is the stable per-occurrence identity time-change detection needs; nil for
    /// non-recurring events and providers that don't expose it. Defaults nil.
    var occurrenceDate: Date? = nil
    /// Which backend produced this event. With both sources merged into one list, an
    /// action on an event must be routed to **its own** provider: sending an EventKit id
    /// to Graph (or vice versa) fails, since the id spaces are unrelated.
    var sourceProvider: CalendarProviderType = .eventKit
    /// True when this event lives on an Exchange-backed calendar, i.e. one whose truth
    /// lives on a Microsoft 365 server that `GraphVerifier` can cross-check. Only
    /// EventKit sets it; nothing else is ever verified. Defaults false, so an event we
    /// aren't sure about is never a verification candidate.
    var isExchangeBacked: Bool = false
    /// The current user's RSVP. Defaults to `.unknown` so events without invitee
    /// data are never accidentally suppressed.
    var myResponse: ResponseStatus = .unknown
    /// Everyone's RSVP breakdown, or nil when no response data is available.
    var responseCounts: ResponseCounts? = nil

    /// Time remaining until the meeting starts, relative to now.
    var timeUntilStart: TimeInterval {
        startDate.timeIntervalSinceNow
    }

    /// Human-readable start time (e.g., "2:30 PM").
    var formattedStartTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }

    /// Whether reminders/recording should be suppressed for this event given the
    /// user's RSVP and their two settings. Single source of truth for all three
    /// gate sites (overlay, notification/voice, recording). Only ever suppresses
    /// `.declined` / `.noResponse` — accepted, tentative, organizer, and unknown
    /// always pass, so personal events and meetings you own are never silenced.
    func suppressedByResponse(skipDeclined: Bool, skipNoResponse: Bool) -> Bool {
        switch myResponse {
        case .declined:   return skipDeclined
        case .noResponse: return skipNoResponse
        default:          return false
        }
    }
}

// MARK: - ResponseStatus display

extension ResponseStatus {
    /// Short human label. nil for states we don't surface (organizer/unknown).
    var label: String? {
        switch self {
        case .accepted:   return "Accepted"
        case .declined:   return "Declined"
        case .tentative:  return "Tentative"
        case .noResponse: return "No response"
        case .organizer:  return "You're organizing"
        case .unknown:    return nil
        }
    }

    /// SF Symbol for the Today-view glyph. nil = no glyph (accepted/organizer/unknown
    /// stay clean to avoid clutter — only non-accepted invitations get a marker).
    var todayGlyph: String? {
        switch self {
        case .declined:   return "person.crop.circle.badge.xmark"
        case .tentative:  return "questionmark.circle"
        case .noResponse: return "person.crop.circle.badge.clock"
        default:          return nil
        }
    }
}

// MARK: - CalendarProviderType

/// The available calendar source types.
enum CalendarProviderType: String, CaseIterable, Identifiable {
    case eventKit = "EventKit"
    case microsoftGraph = "Microsoft Graph"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .eventKit:
            return "Uses calendars configured in macOS System Settings (iCloud, Exchange, Google, etc.)"
        case .microsoftGraph:
            return "Connects directly to Microsoft 365 via Graph API (requires Azure App Registration)"
        }
    }
}

// MARK: - CalendarProvider Protocol

/// Protocol that all calendar sources must conform to.
protocol CalendarProvider {
    /// The type of this provider.
    var providerType: CalendarProviderType { get }

    /// Whether the provider is currently authenticated / has access.
    var isAuthorized: Bool { get }

    /// True when authorizing puts a sign-in UI in front of the user.
    ///
    /// **This MUST stay a protocol requirement.** It lived only in a protocol extension
    /// once, and Swift dispatches extension-only members statically: called through the
    /// existential `CalendarProvider`, it always returned the extension's `false` and
    /// Graph's `true` was never consulted — so the guard meant to stop a poll from
    /// launching a browser sign-in was dead code, and switching provider still ambushed
    /// the user with a login.
    var requiresInteractiveSignIn: Bool { get }

    /// Whether this source can create events. EventKit can; Graph event creation isn't
    /// implemented, so offering it as a write target would be a lie. Declared here (not
    /// in an extension) so the override actually dispatches.
    var canCreateEvents: Bool { get }

    /// Request access to the calendar (may trigger system permission dialog or OAuth flow).
    func requestAccess() async throws -> Bool

    /// Fetch upcoming events within the given time interval from now.
    /// - Parameter interval: How far ahead to look (e.g., 3600 = next hour).
    /// - Returns: An array of `MeetingEvent` sorted by start date.
    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent]

    /// Returns the list of available calendar names (for filtering in settings).
    func availableCalendars() async throws -> [CalendarInfo]

    /// Whether this provider can write an RSVP response. EventKit can't (Apple
    /// blocks programmatic invitation responses); Graph can, once write-scoped.
    var supportsResponding: Bool { get }

    /// Respond to an invitation (accept / decline / tentativelyAccept). Throws
    /// `.notSupported` on backends that can't write the response.
    func respond(to eventID: String, status: ResponseStatus) async throws
}

// MARK: - CalendarInfo

/// Title-prefix fallback detector for cancelled meetings. Used when a calendar
/// source sets the title to `Canceled: ...` / `Cancelled: ...` but doesn't expose
/// the cancellation via the structured status field — common with older Exchange
/// servers that forward invites with a rewritten title.
extension CalendarProvider {
    /// Default: authorizing is silent or a one-time system prompt. EventKit's
    /// `requestAccess` is a macOS permission dialog shown once, so a poll may trigger
    /// it; a Graph sign-in opens a browser plus a consent sheet and must be started by
    /// the user. This is a *default for a declared requirement* — see the protocol.
    var requiresInteractiveSignIn: Bool { false }
    var canCreateEvents: Bool { false }
}

enum CancellationTitlePrefix {
    static func matches(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasPrefix("canceled:") || lower.hasPrefix("cancelled:")
    }
}

/// Lightweight info about a calendar for display in settings.
struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let color: String  // Hex color string for UI display
    let source: String // e.g., "iCloud", "Exchange", "Google"
    /// Which backend produced this calendar. With both sources readable at once, the
    /// list mixes them, and a row must toggle **its own** provider's selection — the two
    /// id spaces are unrelated, so applying an EventKit id to Graph selects nothing.
    var providerType: CalendarProviderType = .eventKit
}

// MARK: - CalendarProviderError

/// Errors that calendar providers can throw.
enum CalendarProviderError: LocalizedError {
    case accessDenied
    case notAuthenticated
    case networkError(underlying: Error)
    case noCalendarsAvailable
    case notSupported
    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access was denied. Please grant permission in System Settings → Privacy & Security → Calendars."
        case .notAuthenticated:
            return "Not authenticated. Please sign in to your calendar account."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noCalendarsAvailable:
            return "No calendars found. Please check your calendar account settings."
        case .notSupported:
            return "Responding to invitations isn't supported for this calendar. Apple's EventKit can't RSVP — use a Microsoft 365 (Graph) account, or respond in Calendar."
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }
}
