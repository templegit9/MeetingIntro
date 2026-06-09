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
        // Attach the join link so the overlay Join button, audio handoff, and
        // auto-record pick it up (they read MeetingEvent.url ← EKEvent.url).
        if let urlString = draft.url, let url = URL(string: urlString) {
            event.url = url
        }

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

    // MARK: - Calendar mirror (v2.5.0)

    enum MirrorError: LocalizedError {
        case notAuthorized
        case destinationNotFound
        case destinationReadOnly(String)
        case noWritableSource
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Calendar access not granted."
            case .destinationNotFound: return "The destination calendar no longer exists."
            case .destinationReadOnly(let name): return "\"\(name)\" is read-only (subscribed/holiday calendars can't be written to). Pick a writable calendar."
            case .noWritableSource: return "No writable calendar source available to create a new calendar."
            case .saveFailed(let d): return "Calendar write failed: \(d)"
            }
        }
    }

    /// A lightweight value describing a mirror event — the engine works in these,
    /// never raw EKEvents (CLAUDE.md boundary rule).
    struct MirrorSourceEvent: Equatable {
        let sourceID: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
    }

    /// A calendar source a new dedicated calendar can be created on.
    struct CreatableSource: Identifiable, Equatable {
        let id: String      // EKSource.sourceIdentifier
        let title: String   // "iCloud", "On My Mac", …
        let isLocal: Bool
    }

    /// Sources EventKit can realistically create a calendar on: iCloud (CalDAV)
    /// and Local. Google / Exchange / M365 reject new-calendar creation, so they
    /// are deliberately omitted — for those, the user mirrors into an existing
    /// calendar instead.
    func creatableSources() -> [CreatableSource] {
        guard isAuthorized else { return [] }
        return eventStore.sources.compactMap { source in
            switch source.sourceType {
            case .local:
                return CreatableSource(id: source.sourceIdentifier, title: source.title, isLocal: true)
            case .calDAV:
                // iCloud is a CalDAV source titled "iCloud". Google is also CalDAV
                // but rejects creation — we still list CalDAV sources and let the
                // save fail loudly rather than hard-code provider names, EXCEPT we
                // can't reliably tell them apart, so prefer the iCloud-titled one.
                return CreatableSource(id: source.sourceIdentifier, title: source.title, isLocal: false)
            default:
                return nil
            }
        }
    }

    /// Default source for new calendars: iCloud if present (syncs to the user's
    /// Apple devices, shareable), else Local.
    func defaultCreatableSourceID() -> String? {
        let sources = creatableSources()
        return sources.first { $0.title.localizedCaseInsensitiveContains("icloud") }?.id
            ?? sources.first { !$0.isLocal }?.id
            ?? sources.first?.id
    }

    /// Create a dedicated calendar on the given source (or the default if nil).
    func createCalendar(named name: String, sourceID: String?) throws -> String {
        guard isAuthorized else { throw MirrorError.notAuthorized }
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = name

        let chosen: EKSource?
        if let sourceID {
            chosen = eventStore.sources.first { $0.sourceIdentifier == sourceID }
        } else if let defID = defaultCreatableSourceID() {
            chosen = eventStore.sources.first { $0.sourceIdentifier == defID }
        } else {
            chosen = eventStore.sources.first { $0.sourceType == .local } ?? eventStore.defaultCalendarForNewEvents?.source
        }
        guard let source = chosen else { throw MirrorError.noWritableSource }
        calendar.source = source

        do {
            try eventStore.saveCalendar(calendar, commit: true)
        } catch {
            throw MirrorError.saveFailed("\(error.localizedDescription) — \"\(source.title)\" may not allow creating new calendars (Google/Exchange typically don't; use an existing calendar there instead).")
        }
        return calendar.calendarIdentifier
    }

    func calendarIsWritable(_ id: String) -> Bool {
        eventStore.calendar(withIdentifier: id)?.allowsContentModifications ?? false
    }

    func calendarName(_ id: String) -> String? {
        eventStore.calendar(withIdentifier: id)?.title
    }

    /// Source events to mirror, in [now, now+window]. Includes all-day. Excludes
    /// anything already carrying our mirror marker (prevents mirror-of-mirror).
    func mirrorSourceEvents(calendarIDs: [String], window: TimeInterval) -> [MirrorSourceEvent] {
        guard isAuthorized else { return [] }
        let cals = eventStore.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !cals.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(window), calendars: cals)
        return eventStore.events(matching: predicate)
            .filter { !MirrorMarker.isMirror($0.url) }
            .map {
                MirrorSourceEvent(
                    sourceID: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Busy",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location,
                    notes: $0.notes
                )
            }
    }

    /// Existing mirror events in the destination for a given mirror, keyed by the
    /// sourceID embedded in their marker → the EKEvent (kept internal to the provider).
    /// Returns a closure-friendly snapshot the engine reconciles against.
    func existingMirrorMap(destinationID: String, mirrorID: UUID) -> [String: EKEvent] {
        guard isAuthorized, let cal = eventStore.calendar(withIdentifier: destinationID) else { return [:] }
        // Wide window so we also catch copies whose source moved out of the sync window.
        let predicate = eventStore.predicateForEvents(
            withStart: Date().addingTimeInterval(-86400 * 2),
            end: Date().addingTimeInterval(86400 * 400),
            calendars: [cal]
        )
        var map: [String: EKEvent] = [:]
        for event in eventStore.events(matching: predicate) {
            if let decoded = MirrorMarker.decode(event.url), decoded.mirrorID == mirrorID {
                map[decoded.sourceID] = event
            }
        }
        return map
    }

    /// Create or update one mirror event for `source` in `destinationID`.
    /// `existing` is the prior copy (from existingMirrorMap) if any.
    func writeMirror(_ source: MirrorSourceEvent, existing: EKEvent?, destinationID: String, mirrorID: UUID, mode: Mirror.DetailMode) throws {
        guard isAuthorized else { throw MirrorError.notAuthorized }
        guard let cal = eventStore.calendar(withIdentifier: destinationID) else { throw MirrorError.destinationNotFound }
        guard cal.allowsContentModifications else { throw MirrorError.destinationReadOnly(cal.title) }

        let event = existing ?? EKEvent(eventStore: eventStore)
        event.calendar = cal
        event.url = MirrorMarker.encode(mirrorID: mirrorID, sourceID: source.sourceID)
        event.startDate = source.startDate
        event.endDate = source.endDate
        event.isAllDay = source.isAllDay
        switch mode {
        case .full:
            event.title = source.title
            event.location = source.location
            event.notes = source.notes
        case .busy:
            event.title = "Busy"
            event.location = nil
            event.notes = nil
        }
        do {
            try eventStore.save(event, span: .thisEvent, commit: false)
        } catch {
            throw MirrorError.saveFailed(error.localizedDescription)
        }
    }

    func deleteMirrorEvents(_ events: [EKEvent]) throws {
        guard isAuthorized else { throw MirrorError.notAuthorized }
        for event in events {
            try? eventStore.remove(event, span: .thisEvent, commit: false)
        }
    }

    /// Commit batched mirror writes/deletes in one transaction.
    func commitMirrorChanges() throws {
        do { try eventStore.commit() }
        catch { throw MirrorError.saveFailed(error.localizedDescription) }
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
