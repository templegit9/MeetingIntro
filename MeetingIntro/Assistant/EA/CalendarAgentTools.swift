import Foundation

// MARK: - Create

/// Create an event. Goes through the same `EventDraft` the Quick Add form produces, so
/// the join link, the calendar routing and the invitee rules are identical whether the
/// event came from typing a sentence or from asking the assistant.
struct CreateEventTool: AgentTool {
    let name = "create_event"
    let description = "Create a calendar event or block time. Use for meetings, holds and all-day events."
    var parameters: [String: Any] {
        Self.schema([
            "title": Self.string("What the event is called"),
            "start": Self.string("Start time, ISO 8601 local, e.g. 2026-09-09T13:00:00"),
            "duration_minutes": Self.integer("Length in minutes. Omit for the default."),
            "all_day": Self.boolean("True for an all-day event"),
            "attendees": Self.stringArray("Email addresses to invite. ONLY addresses the user actually typed — never guess one from a name."),
            "location": Self.string("Where it is, if stated"),
            "repeat": Self.string("One of: daily, weekly, monthly, yearly. Omit for a one-off.")
        ], required: ["title", "start"])
    }

    let calendarManager: CalendarManager
    let defaultDurationMinutes: Int
    let calendarID: String?

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let title = ToolArgs.string(arguments, "title") else {
            throw ToolArgumentError(message: "I didn't catch what the event should be called.")
        }
        var assumptions: [String] = []
        let start: Date
        if let parsed = ToolArgs.date(arguments, "start") {
            start = parsed
        } else {
            start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                          of: Date().addingTimeInterval(86_400)) ?? Date()
            assumptions.append("No start time I could read — assumed tomorrow at 9:00 AM")
        }
        let allDay = ToolArgs.bool(arguments, "all_day") ?? false
        let minutes = ToolArgs.int(arguments, "duration_minutes") ?? defaultDurationMinutes
        if ToolArgs.int(arguments, "duration_minutes") == nil && !allDay {
            assumptions.append("No length given — assumed \(defaultDurationMinutes) minutes")
        }

        var draft = EventDraft(title: title,
                               startDate: allDay ? Calendar.current.startOfDay(for: start) : start,
                               endDate: Date(),
                               parserUsed: .detector)
        draft.isAllDay = allDay
        draft.endDate = allDay
            ? (Calendar.current.date(byAdding: .day, value: 1, to: draft.startDate) ?? draft.startDate)
            : draft.startDate.addingTimeInterval(TimeInterval(minutes * 60))
        draft.location = ToolArgs.string(arguments, "location")
        // Addresses only. A model that decides sam@ is Sam would invite a stranger, and
        // an invitation cannot be taken back.
        draft.attendees = ToolArgs.strings(arguments, "attendees").filter { $0.contains("@") }
        let named = ToolArgs.strings(arguments, "attendees").filter { !$0.contains("@") }
        if !named.isEmpty {
            assumptions.append("Not inviting \(named.joined(separator: ", ")) — I only invite an address you typed")
        }
        draft.recurrence = Self.recurrence(ToolArgs.string(arguments, "repeat"), start: draft.startDate)

        var details = [Self.when(draft)]
        if let location = draft.location { details.append(location) }
        if !draft.attendees.isEmpty { details.append("Inviting \(draft.attendees.joined(separator: ", "))") }
        if let repeats = draft.recurrence { details.append(repeats.label()) }

        var warnings: [String] = []
        let overlaps = calendarManager.conflicts(start: draft.startDate, end: draft.endDate)
        if let first = overlaps.first {
            warnings.append("Overlaps “\(first.title)”" + (overlaps.count > 1 ? " and \(overlaps.count - 1) more" : ""))
        }
        if !draft.attendees.isEmpty, calendarManager.eventCreationProvider != .microsoftGraph {
            warnings.append("Invitations can't be sent from macOS Calendar — pick a Microsoft 365 calendar to invite people")
        }

        let manager = calendarManager
        let target = calendarID
        return ProposedAction(
            kind: .change, title: "Create event", details: details,
            assumptions: assumptions, warnings: warnings, confirmLabel: "Create",
            run: {
                try await manager.createEvent(from: draft, calendarID: target)
                return "Created “\(draft.title)”."
            })
    }

    private static func when(_ draft: EventDraft) -> String {
        let day = draft.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if draft.isAllDay { return "\(day) · all day" }
        return "\(day) · \(draft.startDate.formatted(date: .omitted, time: .shortened))–\(draft.endDate.formatted(date: .omitted, time: .shortened))"
    }

    private static func recurrence(_ raw: String?, start: Date) -> DraftRecurrence? {
        guard let raw = raw?.lowercased() else { return nil }
        let parts = Calendar.current.dateComponents([.weekday, .day, .month], from: start)
        switch raw {
        case "daily": return .daily
        case "weekly": return .weekly(weekday: parts.weekday ?? 2)
        case "monthly": return .monthly(day: parts.day ?? 1)
        case "yearly": return .yearly(month: parts.month ?? 1, day: parts.day ?? 1)
        default: return nil
        }
    }
}

/// Create a to-do. Undoable, unlike a calendar write, so it carries an undo.
struct CreateTaskTool: AgentTool {
    let name = "create_task"
    let description = "Create a to-do item, with an optional deadline."
    var parameters: [String: Any] {
        Self.schema([
            "title": Self.string("What needs doing"),
            "due": Self.string("Deadline, ISO 8601 local. Omit for a task with no deadline."),
            "remind_minutes_before": Self.integer("Reminder lead time in minutes")
        ], required: ["title"])
    }

    let taskManager: TaskManager
    let config: TaskConfig

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let title = ToolArgs.string(arguments, "title") else {
            throw ToolArgumentError(message: "I didn't catch what the task should be.")
        }
        var task = TaskItem(title: title)
        task.dueDate = ToolArgs.date(arguments, "due")
        task.remindLeadMinutes = ToolArgs.int(arguments, "remind_minutes_before") ?? config.defaultRemindLeadMinutes
        task.showOverlay = config.defaultShowOverlay
        task.sendNotification = config.defaultSendNotification
        task.playVoice = config.defaultPlayVoice

        var details: [String] = []
        if let due = task.dueDate {
            details.append("Due \(due.formatted(date: .abbreviated, time: .shortened))")
            details.append(task.remindLeadMinutes == 0 ? "Reminder at the deadline" : "Reminder \(task.remindLeadMinutes) min before")
        } else {
            details.append("No deadline — it won't remind you")
        }

        let manager = taskManager
        let saved = task
        return ProposedAction(
            kind: .change, title: "Add task", details: details, confirmLabel: "Add",
            run: { manager.add(saved); return "Added “\(saved.title)”." },
            undo: { manager.delete(saved.id) })
    }
}

// MARK: - Read

/// Today at a glance. An answer, not a card: reading your own calendar has nothing to
/// confirm and nothing to undo.
struct TodayTool: AgentTool {
    let name = "whats_on_today"
    let description = "List today's meetings and what the day looks like."
    var parameters: [String: Any] { Self.schema([:]) }

    let calendarManager: CalendarManager
    let taskManager: TaskManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let meetings = calendarManager.todaysMeetings.filter { !$0.isCancelled }
        var lines: [String] = []
        if meetings.isEmpty {
            lines.append("Nothing on the calendar today.")
        } else {
            let inMeetings = meetings.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
            lines.append(String(format: "%d meeting%@ · %.1f hours", meetings.count, meetings.count == 1 ? "" : "s", inMeetings))
            for meeting in meetings.prefix(8) {
                lines.append("\(meeting.startDate.formatted(date: .omitted, time: .shortened))  \(meeting.title)")
            }
            if meetings.count > 8 { lines.append("+ \(meetings.count - 8) more") }
        }
        let due = taskManager.tasks.filter { !$0.isCompleted && $0.dueDate != nil }
            .filter { Calendar.current.isDateInToday($0.dueDate!) }
        if !due.isEmpty { lines.append("Tasks due today: \(due.map(\.title).joined(separator: ", "))") }
        return .answer("Today", lines)
    }
}

/// Free slots, computed from the calendar already in memory — no model, no network, and
/// no waiting. This is the answer that makes the assistant feel like one.
struct FindTimeTool: AgentTool {
    let name = "find_time"
    let description = "Find free slots of a given length in the next few days."
    var parameters: [String: Any] {
        Self.schema([
            "duration_minutes": Self.integer("How long the slot needs to be"),
            "days_ahead": Self.integer("How many days to search. Default 5."),
            "earliest_hour": Self.integer("Earliest hour of the day to suggest, 24h. Default 9."),
            "latest_hour": Self.integer("Latest hour a slot may end, 24h. Default 18.")
        ], required: [])
    }

    let calendarManager: CalendarManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let minutes = ToolArgs.int(arguments, "duration_minutes") ?? 30
        let days = min(max(ToolArgs.int(arguments, "days_ahead") ?? 5, 1), 14)
        let earliest = ToolArgs.int(arguments, "earliest_hour") ?? 9
        let latest = ToolArgs.int(arguments, "latest_hour") ?? 18
        let slots = Self.freeSlots(in: calendarManager.upcomingWeek,
                                   minutes: minutes, days: days,
                                   earliestHour: earliest, latestHour: latest)
        guard !slots.isEmpty else {
            return .answer("No free time", ["Nothing \(minutes) minutes long between \(earliest):00 and \(latest):00 in the next \(days) days."])
        }
        let lines = slots.prefix(6).map { slot in
            "\(slot.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))  \(slot.formatted(date: .omitted, time: .shortened))"
        }
        return .answer("Free for \(minutes) min", Array(lines))
    }

    /// Busy blocks are merged first, so back-to-back meetings don't produce a phantom
    /// gap between them, and a slot must fit entirely inside working hours.
    static func freeSlots(in events: [MeetingEvent], minutes: Int, days: Int,
                          earliestHour: Int, latestHour: Int,
                          now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let length = TimeInterval(minutes * 60)
        let busy = events
            .filter { !$0.isAllDay && !$0.isCancelled }
            .map { ($0.startDate, $0.endDate) }
            .sorted { $0.0 < $1.0 }
            .reduce(into: [(Date, Date)]()) { merged, block in
                if let last = merged.last, block.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, block.1)
                } else {
                    merged.append(block)
                }
            }

        var found: [Date] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let dayStart = calendar.date(bySettingHour: earliestHour, minute: 0, second: 0, of: day),
                  let dayEnd = calendar.date(bySettingHour: latestHour, minute: 0, second: 0, of: day)
            else { continue }
            var cursor = max(dayStart, offset == 0 ? Self.roundUp(now, calendar: calendar) : dayStart)
            for block in busy where block.1 > cursor && block.0 < dayEnd {
                if block.0.timeIntervalSince(cursor) >= length { found.append(cursor) }
                cursor = max(cursor, block.1)
            }
            if dayEnd.timeIntervalSince(cursor) >= length { found.append(cursor) }
            if found.count >= 6 { break }
        }
        return found
    }

    /// Suggesting "10:03" is the kind of detail that makes a tool feel machine-made.
    private static func roundUp(_ date: Date, calendar: Calendar) -> Date {
        let minute = calendar.component(.minute, from: date)
        let bump = (15 - minute % 15) % 15
        return calendar.date(bySetting: .second, value: 0, of: date.addingTimeInterval(TimeInterval(bump * 60))) ?? date
    }
}
