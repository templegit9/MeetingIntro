import Foundation

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

    /// Request access to the calendar (may trigger system permission dialog or OAuth flow).
    func requestAccess() async throws -> Bool

    /// Fetch upcoming events within the given time interval from now.
    /// - Parameter interval: How far ahead to look (e.g., 3600 = next hour).
    /// - Returns: An array of `MeetingEvent` sorted by start date.
    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent]

    /// Returns the list of available calendar names (for filtering in settings).
    func availableCalendars() async throws -> [CalendarInfo]
}

// MARK: - CalendarInfo

/// Lightweight info about a calendar for display in settings.
struct CalendarInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let color: String  // Hex color string for UI display
    let source: String // e.g., "iCloud", "Exchange", "Google"
}

// MARK: - CalendarProviderError

/// Errors that calendar providers can throw.
enum CalendarProviderError: LocalizedError {
    case accessDenied
    case notAuthenticated
    case networkError(underlying: Error)
    case noCalendarsAvailable
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
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }
}
