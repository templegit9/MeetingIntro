import EventKit
import Foundation

/// Calendar provider implementation using Apple's EventKit framework.
/// Reads events from calendars configured in macOS System Settings → Internet Accounts.
final class EventKitProvider: CalendarProvider {

    let providerType: CalendarProviderType = .eventKit

    private let eventStore = EKEventStore()

    /// Set of calendar identifiers the user has chosen to monitor (empty = all).
    var selectedCalendarIDs: Set<String> = []

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async throws -> Bool {
        let granted = try await eventStore.requestFullAccessToEvents()
        if !granted {
            throw CalendarProviderError.accessDenied
        }
        return granted
    }

    func fetchUpcomingEvents(within interval: TimeInterval) async throws -> [MeetingEvent] {
        if !isAuthorized {
            let granted = try await requestAccess()
            if !granted { return [] }
        }

        let now = Date()
        let endDate = now.addingTimeInterval(interval)

        let calendars = calendarsToSearch()
        let predicate = eventStore.predicateForEvents(withStart: now, end: endDate, calendars: calendars)
        let ekEvents = eventStore.events(matching: predicate)

        return ekEvents
            .filter { !$0.isAllDay } // Skip all-day events by default for meeting countdown
            .map { event in
                let attendees = (event.attendees ?? []).compactMap { $0.name }
                let joinURL = ConferenceLinkExtractor.bestURL(
                    eventURL: event.url,
                    notes: event.notes,
                    location: event.location
                )
                return MeetingEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled Meeting",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    calendarName: event.calendar?.title ?? "Unknown",
                    location: event.location,
                    isAllDay: event.isAllDay,
                    url: joinURL,
                    notes: event.notes,
                    attendeeNames: Array(attendees.prefix(10)),
                    attendeeCount: attendees.count,
                    organizerName: event.organizer?.name
                )
            }
            .sorted { $0.startDate < $1.startDate }
    }

    func availableCalendars() async throws -> [CalendarInfo] {
        if !isAuthorized {
            _ = try await requestAccess()
        }

        return eventStore.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                name: cal.title,
                color: cal.cgColor?.hexString ?? "#007AFF",
                source: cal.source?.title ?? "Local"
            )
        }
    }

    // MARK: - Private

    private func calendarsToSearch() -> [EKCalendar]? {
        if selectedCalendarIDs.isEmpty { return nil } // nil = search all
        return eventStore.calendars(for: .event).filter {
            selectedCalendarIDs.contains($0.calendarIdentifier)
        }
    }
}

// MARK: - CGColor Hex Extension

import CoreGraphics

extension CGColor {
    var hexString: String {
        guard let components = components, components.count >= 3 else { return "#007AFF" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
