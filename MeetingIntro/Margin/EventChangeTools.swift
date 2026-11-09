import Foundation

/// Changing a meeting that already exists.
///
/// These two are the first Margin tools that alter something other people can see, and
/// the pages reflect that: a move states the old time as well as the new one, and a
/// cancellation says **exactly who finds out** — which differs by backend, and cannot be
/// glossed over. Both name the meeting they matched before doing anything, because acting
/// on the wrong meeting is not something an undo can fully repair once attendees have
/// been emailed.

/// Shared lookup: find the one meeting a phrase means, or hand back a page that asks.
enum MeetingLookup {
    /// Time-only references mean today; repeated names require an explicit date.
    static func matches(_ needle: String, events: [MeetingEvent], originalStart: Date? = nil,
                        now: Date = Date()) -> [MeetingEvent] {
        let query = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || originalStart != nil else { return [] }
        let clock = clockTime(query)
        return events.filter { event in
            guard !event.isCancelled, event.endDate > now else { return false }
            if let originalStart, abs(event.startDate.timeIntervalSince(originalStart)) >= 1 { return false }
            if let clock {
                let cal = Calendar.current
                return (originalStart != nil || cal.isDate(event.startDate, inSameDayAs: now))
                    && cal.component(.hour, from: event.startDate) == clock.hour
                    && cal.component(.minute, from: event.startDate) == clock.minute
            }
            return query.isEmpty || event.title.localizedCaseInsensitiveContains(query)
        }.sorted { $0.startDate < $1.startDate }
    }

    static func clockTime(_ query: String) -> (hour: Int, minute: Int)? {
        let value = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard value.range(of: #"^([1-9]|1[0-2])(:[0-5][0-9])?(am|pm)$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.dropLast(2).split(separator: ":")
        let hour = Int(parts[0])! % 12 + (value.hasSuffix("pm") ? 12 : 0)
        return (hour, parts.count == 2 ? Int(parts[1])! : 0)
    }

    static func ambiguous(_ meetings: [MeetingEvent]) -> ProposedAction {
        ProposedAction(kind: .answer, title: "Which meeting?",
                       details: meetings.map { "\($0.title) · \(label($0)) · \($0.calendarName)" },
                       provenance: "Several meetings match. Include the meeting name and original date/time; nothing was changed.",
                       run: { _ in "" })
    }

    static func notFound(_ needle: String) -> ProposedAction {
        ProposedAction(kind: .answer, title: "Not found",
                       details: ["No upcoming meeting called “\(needle)”."],
                       provenance: "Nothing was changed.", run: { _ in "" })
    }

    static func label(_ meeting: MeetingEvent) -> String {
        "\(meeting.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(meeting.startDate.formatted(date: .omitted, time: .shortened))"
    }
}

/// Move a meeting to a new time.
struct MoveEventTool: AgentTool {
    let name = "move_event"
    let description = "Move an existing meeting to a different time. Use for 'move my 3pm to 4pm', 'push the standup to 10', 'shift the review to Thursday'."
    var humanSummary: String { "move a meeting to a different time" }
    func workingPhrase(_ arguments: [String: Any]) -> String { "finding that meeting…" }
    var parameters: [String: Any] {
        Self.schema([
            "title": Self.string("All or part of the meeting's name, or the time it starts now, e.g. '3pm'. Required unless original_start is supplied."),
            "new_start": Self.string("New start, ISO 8601 local, e.g. 2026-09-11T16:00:00. Omit when only a new day was requested."),
            "new_date": Self.string("New date YYYY-MM-DD when no new time was given. The tool preserves the existing meeting time."),
            "original_start": Self.string("Original start as ISO 8601 ONLY when both original date and clock time were supplied. Never assume midnight; use original_date for a day without a time."),
            "original_date": Self.string("Original day YYYY-MM-DD, e.g. tomorrow, when original clock time is unknown."),
            "keep_duration": Self.boolean("Keep the same length. Default true unless duration_minutes is supplied."),
            "duration_minutes": Self.integer("New length in minutes, if it should change")
        ], required: [])
    }

    static func targetStart(_ a: [String: Any], existing: Date, calendar: Calendar = .current) throws -> Date {
        if let start = ToolArgs.date(a, "new_start") { return start }
        guard let raw = ToolArgs.string(a, "new_date"), raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = ToolArgs.date(a, "new_date") else { throw ToolArgumentError(message: "Give a target date as YYYY-MM-DD or a full new start time.") }
        let time = calendar.dateComponents([.hour, .minute, .second], from: existing)
        guard let result = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: date) else {
            throw ToolArgumentError(message: "That local time does not exist on the selected date.")
        }
        return result
    }

    let calendarManager: CalendarManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let needle = ToolArgs.string(arguments, "title") ?? ""
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ToolArgs.date(arguments, "original_start") != nil else {
            throw ToolArgumentError(message: "Which meeting? Give its name or original date and time.")
        }
        guard ToolArgs.date(arguments, "new_start") != nil || ToolArgs.date(arguments, "new_date") != nil else {
            throw ToolArgumentError(message: "Which date or time should it move to?")
        }
        if arguments["original_start"] != nil && ToolArgs.date(arguments, "original_start") == nil {
            throw ToolArgumentError(message: "What is the original date and time?")
        }
        if arguments["original_date"] != nil && ToolArgs.date(arguments, "original_date") == nil {
            throw ToolArgumentError(message: "What is the original meeting date?")
        }
        let candidates = ToolArgs.date(arguments, "original_date").map { day in
            calendarManager.upcomingWeek.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
        } ?? calendarManager.upcomingWeek
        let found = MeetingLookup.matches(needle, events: candidates,
                                          originalStart: ToolArgs.date(arguments, "original_start"))
        guard let meeting = found.first else { return MeetingLookup.notFound(needle.isEmpty ? "at that time" : needle) }
        guard found.count == 1 else { return MeetingLookup.ambiguous(found) }
        let newStart = try Self.targetStart(arguments, existing: meeting.startDate)

        guard calendarManager.canModify(meeting) else {
            return ProposedAction(
                kind: .answer, title: "Can't move that one",
                details: ["\(meeting.title) · \(meeting.calendarName)", "\(meeting.calendarName) can't be changed from here."],
                provenance: "Nothing was changed.", run: { _ in "" })
        }

        if ToolArgs.bool(arguments, "keep_duration") == false && arguments["duration_minutes"] == nil {
            throw ToolArgumentError(message: "How many minutes should the meeting last?")
        }
        if let raw = arguments["duration_minutes"],
           Double(String(describing: raw)).map({ !$0.isFinite || $0 <= 0 || $0 > 10080 || $0.rounded() != $0 }) ?? true {
            throw ToolArgumentError(message: "Use a whole number of minutes between 1 and 10080.")
        }
        let length = ToolArgs.int(arguments, "duration_minutes").map { TimeInterval($0) * 60 }
            ?? meeting.endDate.timeIntervalSince(meeting.startDate)
        guard length > 0, newStart > Date() else {
            throw ToolArgumentError(message: "Choose a future start and a positive duration.")
        }
        let newEnd = newStart.addingTimeInterval(length)
        try await calendarManager.validateEventChange(meeting, moving: true)

        var warnings: [String] = []
        // Clashes at the NEW time, excluding the meeting itself — the single most useful
        // thing to know before agreeing to a move.
        let clashes = calendarManager.conflicts(start: newStart, end: newEnd)
            .filter { $0.id != meeting.id }
        if let first = clashes.first {
            warnings.append("Overlaps “\(first.title)”" + (clashes.count > 1 ? " and \(clashes.count - 1) more" : ""))
        }
        if meeting.attendeeCount > 0 {
            warnings.append(meeting.sourceProvider == .microsoftGraph
                            ? "\(meeting.attendeeCount) attendees are told about the new time"
                            : "Your calendar service may send updates to attendees")
        }
        if meeting.isRecurring {
            warnings.append("This occurrence only — the rest of the series stays where it is")
        }

        let manager = calendarManager
        warnings.append("No automatic undo. To move it back, request another move; attendees may receive another update.")
        return ProposedAction(
            kind: .change,
            title: "Move meeting",
            details: ["\(meeting.title) · \(meeting.calendarName)",
                      "\(MeetingLookup.label(meeting)) → \(newStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(newStart.formatted(date: .omitted, time: .shortened))",
                      "\(Int(length / 60)) minutes"],
            warnings: warnings,
            confirmLabel: "Move it",
            // It reaches the attendees when the backend can tell them.
            tearOut: meeting.attendeeCount > 0,
            run: { _ in
                try await manager.moveEvent(meeting, to: newStart, end: newEnd)
                return "Moved “\(meeting.title)” to \(newStart.formatted(date: .abbreviated, time: .shortened))."
            })
    }
}

/// Cancel a meeting — or, where that isn't possible, remove it from your calendar.
struct CancelEventTool: AgentTool {
    let name = "cancel_event"
    let description = "Cancel a meeting you organise, or remove one from your calendar. Use for 'cancel my 2pm', 'call off the review', 'take the standup off my calendar'."
    var humanSummary: String { "cancel a meeting, or take it off your calendar" }
    func workingPhrase(_ arguments: [String: Any]) -> String { "finding that meeting…" }
    var parameters: [String: Any] {
        Self.schema(["title": Self.string("All or part of the meeting's name, or when it starts. Required unless original_start is supplied."),
                     "original_start": Self.string("Original start as ISO 8601, only if the user specifies a date to distinguish matches.")],
                    required: [])
    }

    let calendarManager: CalendarManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let needle = ToolArgs.string(arguments, "title") ?? ""
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ToolArgs.date(arguments, "original_start") != nil else {
            throw ToolArgumentError(message: "Which meeting? Give its name or original date and time.")
        }
        if arguments["original_start"] != nil && ToolArgs.date(arguments, "original_start") == nil {
            throw ToolArgumentError(message: "What is the original date and time?")
        }
        let found = MeetingLookup.matches(needle, events: calendarManager.upcomingWeek,
                                          originalStart: ToolArgs.date(arguments, "original_start"))
        guard let meeting = found.first else { return MeetingLookup.notFound(needle.isEmpty ? "at that time" : needle) }
        guard found.count == 1 else { return MeetingLookup.ambiguous(found) }

        guard calendarManager.canModify(meeting) else {
            return ProposedAction(
                kind: .answer, title: "Can't cancel that one",
                details: ["\(meeting.title) · \(meeting.calendarName)", "\(meeting.calendarName) can't be changed from here."],
                provenance: "Nothing was changed.", run: { _ in "" })
        }

        // The whole point of this page: saying which of the two things is about to happen.
        try await calendarManager.validateEventChange(meeting, moving: false)
        let removeOnly = calendarManager.cancelMeansRemoveOnly(meeting)
        var warnings: [String] = []
        if removeOnly {
            warnings.append("This removes the event through macOS Calendar. Your calendar service may notify the organiser or attendees; this is not a silent local removal.")
        } else if meeting.attendeeCount > 0 {
            warnings.append("\(meeting.attendeeCount) attendees are sent a cancellation")
        }
        if meeting.isRecurring {
            warnings.append("This occurrence only — the rest of the series stays")
        }
        // Deliberately no undo: neither backend can un-send a cancellation, and EventKit
        // deletion is not recoverable from here. A page that offered one would be lying,
        // so it says so instead.
        warnings.append("This can't be undone from here")

        let manager = calendarManager
        return ProposedAction(
            kind: .change,
            title: removeOnly ? "Remove from your calendar" : "Cancel meeting",
            details: ["\(meeting.title) · \(meeting.calendarName)", MeetingLookup.label(meeting)],
            warnings: warnings,
            confirmLabel: removeOnly ? "Remove it" : "Cancel it",
            tearOut: meeting.attendeeCount > 0,
            run: { _ in
                try await manager.cancelEvent(meeting)
                return removeOnly
                    ? "Removed “\(meeting.title)” from your calendar."
                    : "Cancelled “\(meeting.title)”."
            })
    }
}
