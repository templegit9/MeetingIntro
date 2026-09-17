import Foundation
import Combine

/// What has happened to one invitation since the user touched it.
///
/// Deliberately **in-memory only**. An answered card lingers for the session so you can
/// see what you just did and take it back; a relaunch should be a clean slate, not a
/// list of stale receipts for decisions you already made.
enum InvitationState: Equatable {
    /// Optimistically sending. The card stays where it is and **still counts as
    /// awaiting**, because nothing has reached the organizer yet.
    case sending(ResponseStatus)
    /// The send failed. `message` names the consequence, not the error.
    case failed(ResponseStatus, message: String)
    /// Answered. `previous` is what the response was beforehand, which is what decides
    /// whether a true undo is even possible.
    case answered(ResponseStatus, previous: ResponseStatus, at: Date)
}

/// One invitation answered during this session — the dashed lingering row.
struct AnsweredInvitation: Identifiable {
    var event: MeetingEvent
    var status: ResponseStatus
    var previous: ResponseStatus
    var at: Date
    var id: String { event.id }
}

/// Owns the answering of invitations: which ones are still waiting, what is in flight,
/// and what failed.
///
/// **It exists because `try? await` made failure invisible.** Every RSVP call site used
/// to swallow its error, so a decline that never reached the organizer looked exactly
/// like one that did. Nothing else in the invitations design can be built on top of
/// that — a card that reports "wasn't notified" is impossible if the failure never
/// arrives. Separate from `CalendarManager` for the same reason the other coordinators
/// are: it's UI-facing state about the user's actions, not calendar truth.
@MainActor
final class InvitationCenter: ObservableObject {
    @Published private(set) var states: [String: InvitationState] = [:]

    /// Ids the user reopened via "Change…" — they re-enter the awaiting list even though
    /// they now carry a real response, because the user has said they want to change it.
    @Published private(set) var reopened: Set<String> = []

    private weak var calendarManager: CalendarManager?
    var diagnosticLog: DiagnosticLog?

    func attach(calendarManager: CalendarManager) {
        self.calendarManager = calendarManager
    }

    // MARK: - What the section shows

    /// The widest view of the calendar we have. The browse window is what surfaces an
    /// invitation three weeks out; `upcomingWeek` is the fallback before it has loaded.
    private var visibleEvents: [MeetingEvent] {
        guard let cm = calendarManager else { return [] }
        return cm.browseEvents.isEmpty ? cm.upcomingWeek : cm.browseEvents
    }

    /// Invitations still needing an answer, soonest first.
    ///
    /// **Accounts that can't reply are included on purpose.** You need to know an iCloud
    /// invitation is waiting even though Apple gives us no API to answer it — that card
    /// offers Open in Calendar rather than three buttons that can't work. Hiding it
    /// would mean the app quietly decides which of your invitations you get to see.
    ///
    /// In-flight and failed sends stay in the list: neither has reached the organizer.
    var awaiting: [MeetingEvent] {
        let now = Date()
        return visibleEvents
            .filter { !$0.isCancelled && $0.startDate > now }
            .filter { event in
                if case .answered = states[event.id] { return false }
                if states[event.id] != nil { return true }          // sending / failed
                if reopened.contains(event.id) { return true }      // "Change…"
                return event.myResponse == .noResponse
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Answered during this session, newest first.
    var recentlyAnswered: [AnsweredInvitation] {
        states.compactMap { id, state -> AnsweredInvitation? in
            guard case .answered(let status, let previous, let at) = state,
                  let event = visibleEvents.first(where: { $0.id == id }) else { return nil }
            return AnsweredInvitation(event: event, status: status, previous: previous, at: at)
        }
        .sorted { $0.at > $1.at }
    }

    func state(for id: String) -> InvitationState? { states[id] }

    // MARK: - Answering

    func respond(to meeting: MeetingEvent, status: ResponseStatus) async {
        guard let cm = calendarManager else { return }
        let previous = meeting.myResponse
        states[meeting.id] = .sending(status)

        do {
            try await cm.respond(to: meeting, status: status)
            states[meeting.id] = .answered(status, previous: previous, at: Date())
            reopened.remove(meeting.id)
            diagnosticLog?.info(.calendar, "Invitation \(status.rawValue): \"\(meeting.title)\"")
        } catch {
            states[meeting.id] = .failed(status, message: Self.failureMessage(status: status, meeting: meeting))
            diagnosticLog?.error(.calendar,
                "Invitation \(status.rawValue) FAILED for \"\(meeting.title)\" — \(error.localizedDescription)")
        }
    }

    func retry(_ meeting: MeetingEvent) async {
        guard case .failed(let status, _) = states[meeting.id] else { return }
        await respond(to: meeting, status: status)
    }

    /// True undo is only possible when there was a real previous response to put back.
    ///
    /// **No calendar API can return an invitation to "no response."** Graph will change
    /// accepted→declined all day, but it cannot un-answer. So after a first reply the
    /// honest affordance is "Change…", which reopens the actions — not an "Undo" whose
    /// label promises something it can't deliver. This is the one place the design's
    /// wording had to bend, and it bends toward not lying.
    func canUndo(_ id: String) -> Bool {
        guard case .answered(_, let previous, _) = states[id] else { return false }
        return [.accepted, .declined, .tentative].contains(previous)
    }

    func undo(_ meeting: MeetingEvent) async {
        guard case .answered(_, let previous, _) = states[meeting.id], canUndo(meeting.id) else { return }
        await respond(to: meeting, status: previous)
    }

    /// Put an answered invitation back in the list so its actions are available again.
    func reopen(_ meeting: MeetingEvent) {
        states[meeting.id] = nil
        reopened.insert(meeting.id)
    }

    /// Drop the lingering row without changing the answer.
    func dismiss(_ id: String) {
        states[id] = nil
        reopened.remove(id)
    }

    /// Keep the in-memory maps bounded: forget anything whose meeting has left the
    /// window or already started. Conservative — an id transiently missing from a fetch
    /// is left alone, since dropping it would only lose a receipt, never an answer.
    func prune() {
        let live = Set(visibleEvents.filter { $0.startDate > Date() }.map(\.id))
        let gone = states.keys.filter { !live.contains($0) }
        for id in gone where !isInFlight(id) { states[id] = nil }
        reopened.formIntersection(live)
    }

    private func isInFlight(_ id: String) -> Bool {
        if case .sending = states[id] { return true }
        return false
    }

    /// Names the CONSEQUENCE, not the error. What matters to the reader is that a person
    /// is still expecting an answer — not that an HTTP call failed. The underlying error
    /// goes to the diagnostic log, where it's useful, rather than onto a card where it
    /// isn't.
    private static func failureMessage(status: ResponseStatus, meeting: MeetingEvent) -> String {
        let who = meeting.organizerName?.isEmpty == false ? meeting.organizerName! : "the organizer"
        return "\(status.sentVerb) didn't send — \(who) wasn't notified"
    }
}

extension ResponseStatus {
    /// Past tense, for the lingering row: "Q4 planning offsite · accepted".
    var pastLabel: String {
        switch self {
        case .accepted:  return "accepted"
        case .declined:  return "declined"
        case .tentative: return "tentative"
        default:         return "answered"
        }
    }

    /// The verb as it appears on a button and in a failure line: "Accept didn't send".
    var sentVerb: String {
        switch self {
        case .accepted:  return "Accept"
        case .declined:  return "Decline"
        case .tentative: return "Tentative"
        default:         return "Reply"
        }
    }
}
