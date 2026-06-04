import EventKit
import Foundation

/// Calendar provider implementation using Apple's EventKit framework.
/// Reads events from calendars configured in macOS System Settings → Internet Accounts.
final class EventKitProvider: CalendarProvider {

    let providerType: CalendarProviderType = .eventKit

    let eventStore = EKEventStore()

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
                let title = event.title ?? "Untitled Meeting"
                let cancelled = event.status == .canceled || CancellationTitlePrefix.matches(title)
                return MeetingEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: title,
                    startDate: event.startDate,
                    endDate: event.endDate,
                    calendarName: event.calendar?.title ?? "Unknown",
                    location: event.location,
                    isAllDay: event.isAllDay,
                    url: joinURL,
                    notes: event.notes,
                    attendeeNames: Array(attendees.prefix(10)),
                    attendeeCount: attendees.count,
                    organizerName: event.organizer?.name,
                    isCancelled: cancelled
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

    // MARK: - Event creation (Quick Add)

    enum CreateError: LocalizedError {
        case notAuthorized
        case calendarNotFound
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Calendar access not granted."
            case .calendarNotFound: return "The selected calendar no longer exists — pick another in Settings → Quick Add."
            case .saveFailed(let e): return "Couldn't save the event: \(e.localizedDescription)"
            }
        }
    }

    /// Create a calendar event from a Quick Add draft. The EKEvent never leaves this
    /// provider (CLAUDE.md boundary rule). Full Access (already granted for reading)
    /// covers writes — no new permission prompt.
    ///
    /// Known EventKit limitation: attendees cannot be set programmatically (Apple
    /// blocks it), so drafts never carry invitees in the EventKit v1 of Quick Add.
    func createEvent(from draft: EventDraft, calendarID: String?) throws {
        guard isAuthorized else { throw CreateError.notAuthorized }

        let event = EKEvent(eventStore: eventStore)
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.location = draft.location
        event.notes = draft.notes

        if let calendarID, !calendarID.isEmpty {
            guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
                throw CreateError.calendarNotFound
            }
            event.calendar = calendar
        } else {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            throw CreateError.saveFailed(error)
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
