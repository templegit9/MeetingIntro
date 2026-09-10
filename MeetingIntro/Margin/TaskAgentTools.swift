import Foundation

/// Tasks and the day, wired over state the app already publishes.
///
/// These cost nothing to answer — no model round trip after the routing call, no network,
/// no disk — which is exactly why they belong in the registry: the questions people ask an
/// assistant most often are the ones it should answer instantly.

/// What's outstanding. An answer you can act on: pick a line and tick it.
struct ListTasksTool: AgentTool {
    let name = "list_tasks"
    func workingPhrase(_ a: [String: Any]) -> String { "reading your list…" }
    let description = "List outstanding to-dos, optionally only the ones due soon or overdue. Use for 'what's on my list', 'what's overdue', 'what's due this week'."
    var humanSummary: String { "list what's outstanding, and tick things off" }
    var parameters: [String: Any] {
        Self.schema([
            "scope": Self.string("One of: all, overdue, today, week. Default all."),
            "limit": Self.integer("How many to list. Default 20.")
        ], required: [])
    }

    let taskManager: TaskManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let scope = (ToolArgs.string(arguments, "scope") ?? "all").lowercased()
        let limit = min(max(ToolArgs.int(arguments, "limit") ?? 20, 1), 100)
        let open = taskManager.tasks.filter { !$0.isCompleted }
        let now = Date()
        let calendar = Calendar.current

        let matching: [TaskItem]
        switch scope {
        case "overdue":
            matching = open.filter { ($0.dueDate ?? .distantFuture) < now }
        case "today":
            matching = open.filter { $0.dueDate.map { calendar.isDateInToday($0) } ?? false }
        case "week":
            let end = now.addingTimeInterval(7 * 86_400)
            matching = open.filter { ($0.dueDate ?? .distantFuture) <= end }
        default:
            matching = open
        }

        guard !matching.isEmpty else {
            return ProposedAction(
                kind: .answer,
                title: scope == "all" ? "Nothing outstanding" : "Nothing \(scope)",
                details: [open.isEmpty
                          ? "Your list is empty."
                          : "\(open.count) task\(open.count == 1 ? "" : "s") on the list, none \(scope)."],
                run: { _ in "" })
        }

        // Overdue first, then by deadline, then the undated — the order you'd read them in.
        let sorted = matching.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.title < b.title
            }
        }.prefix(limit)

        let overdue = sorted.filter { ($0.dueDate ?? .distantFuture) < now }
        let rest = sorted.filter { ($0.dueDate ?? .distantFuture) >= now }
        var groups: [PageGroup] = []
        if !overdue.isEmpty {
            groups.append(PageGroup(id: "overdue", label: "Overdue",
                                    choices: overdue.map { Self.choice($0, now: now, tone: .caution) }))
        }
        if !rest.isEmpty {
            groups.append(PageGroup(id: "open", label: overdue.isEmpty ? "Outstanding" : "Coming up",
                                    choices: rest.map { Self.choice($0, now: now, tone: .normal) }))
        }

        let manager = taskManager
        return ProposedAction(
            kind: .answer,
            title: "\(matching.count) task\(matching.count == 1 ? "" : "s")",
            groups: groups,
            provenance: overdue.isEmpty ? nil : "\(overdue.count) already past its deadline.",
            confirmLabel: "Mark done",
            run: { picked in
                guard let picked, var task = manager.tasks.first(where: { $0.id == picked }) else {
                    return "Pick one first."
                }
                task.isCompleted = true
                manager.update(task)
                return "Ticked off “\(task.title)”."
            })
    }

    private static func choice(_ task: TaskItem, now: Date, tone: PageChoice.Tone) -> PageChoice {
        var note: String?
        if let due = task.dueDate {
            note = due < now
                ? "overdue · \(due.formatted(date: .abbreviated, time: .omitted))"
                : "due \(due.formatted(date: .abbreviated, time: .shortened))"
        }
        return PageChoice(id: task.id, label: task.title, note: note, tone: tone)
    }
}

/// Tick something off by name.
struct CompleteTaskTool: AgentTool {
    let name = "complete_task"
    func workingPhrase(_ a: [String: Any]) -> String { "finding that task…" }
    let description = "Mark a to-do as done, found by its name. Use for 'mark the expense report done', 'I've sent the deck'."
    var humanSummary: String { "tick a to-do off" }
    var parameters: [String: Any] {
        Self.schema(["title": Self.string("All or part of the task's name")], required: ["title"])
    }

    let taskManager: TaskManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let needle = ToolArgs.string(arguments, "title") else {
            throw ToolArgumentError(message: "Which one?")
        }
        let open = taskManager.tasks.filter { !$0.isCompleted }
        let matches = open.filter { $0.title.localizedCaseInsensitiveContains(needle) }

        guard !matches.isEmpty else {
            return ProposedAction(
                kind: .answer, title: "Not on the list",
                details: ["Nothing outstanding called “\(needle)”."],
                provenance: open.isEmpty
                    ? "Your list is empty."
                    : "\(open.count) task\(open.count == 1 ? "" : "s") outstanding.",
                run: { _ in "" })
        }

        let manager = taskManager

        // More than one match is a question, not a guess. Ticking off the wrong task
        // throws away the reminder that would have caught it.
        if matches.count > 1 {
            return ProposedAction(
                kind: .change,
                title: "Which one?",
                groups: [PageGroup(id: "matches", label: "\(matches.count) match “\(needle)”",
                                   choices: matches.map { task in
                                       PageChoice(id: task.id, label: task.title,
                                                  note: task.dueDate.map { "due \($0.formatted(date: .abbreviated, time: .omitted))" })
                                   })],
                confirmLabel: "Mark done",
                run: { picked in
                    guard let picked, var task = manager.tasks.first(where: { $0.id == picked }) else {
                        return "Pick one first."
                    }
                    task.isCompleted = true
                    manager.update(task)
                    Self.lastCompleted = task.id
                    return "Ticked off “\(task.title)”."
                },
                undo: {
                    guard let id = Self.lastCompleted,
                          var task = manager.tasks.first(where: { $0.id == id }) else { return }
                    task.isCompleted = false
                    manager.update(task)
                    Self.lastCompleted = nil
                })
        }

        let task = matches[0]
        return ProposedAction(
            kind: .change,
            title: "Mark done",
            details: [task.title] + (task.dueDate.map { ["due \($0.formatted(date: .abbreviated, time: .shortened))"] } ?? []),
            confirmLabel: "Mark done",
            run: { _ in
                var updated = task
                updated.isCompleted = true
                manager.update(updated)
                return "Ticked off “\(task.title)”."
            },
            undo: {
                var restored = task
                restored.isCompleted = false
                manager.update(restored)
            })
    }

    /// Which task the multi-match page actually ticked, so undo reverses that one rather
    /// than whichever still matches the words.
    @MainActor private static var lastCompleted: String?
}

/// The shape of the day, in the order you'd want to hear it.
struct DayBriefingTool: AgentTool {
    let name = "day_briefing"
    func workingPhrase(_ a: [String: Any]) -> String { "reading your calendar…" }
    let description = "Summarise the day: how many meetings, when the first and last are, the longest gap, back-to-back runs, and what's due. Use for 'how does my day look', 'brief me', 'what am I in for today'."
    var humanSummary: String { "brief you on the shape of your day" }
    var parameters: [String: Any] {
        Self.schema(["day": Self.string("Which day, YYYY-MM-DD. Default today.")], required: [])
    }

    let calendarManager: CalendarManager
    let taskManager: TaskManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let calendar = Calendar.current
        let day = ToolArgs.date(arguments, "day") ?? Date()
        let isToday = calendar.isDateInToday(day)
        let onDay = calendarManager.events(on: day).filter { !$0.isCancelled }
        let meetings = onDay.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        let allDay = onDay.filter(\.isAllDay)

        var lines: [String] = []
        if meetings.isEmpty {
            lines.append(allDay.isEmpty ? "No meetings." : "No timed meetings.")
        } else {
            let hours = meetings.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600
            lines.append(String(format: "%d meeting%@ · %.1f hours · %@ to %@",
                                meetings.count, meetings.count == 1 ? "" : "s", hours,
                                meetings[0].startDate.formatted(date: .omitted, time: .shortened),
                                meetings.last!.endDate.formatted(date: .omitted, time: .shortened)))

            if let run = MarginNudgeEngine.backToBackRun(meetings, now: calendar.startOfDay(for: day)),
               run.count >= 2 {
                lines.append("\(run.count) back-to-back from \(run[0].startDate.formatted(date: .omitted, time: .shortened))")
            }
            if let gap = Self.longestGap(meetings) {
                lines.append("Longest gap: \(Int(gap.length / 60)) min from \(gap.start.formatted(date: .omitted, time: .shortened))")
            }
            let clashes = Self.clashes(meetings)
            if !clashes.isEmpty {
                lines.append("\(clashes.count) overlap\(clashes.count == 1 ? "" : "s"): \(clashes.joined(separator: ", "))")
            }
            let unanswered = meetings.filter { $0.myResponse == .noResponse }
            if !unanswered.isEmpty {
                lines.append("\(unanswered.count) invitation\(unanswered.count == 1 ? "" : "s") unanswered")
            }
            let noLink = meetings.filter { $0.url == nil }
            if !noLink.isEmpty { lines.append("\(noLink.count) with no join link") }
        }
        for event in allDay.prefix(3) { lines.append("All day: \(event.title)") }

        let due = taskManager.tasks.filter { task in
            guard !task.isCompleted, let date = task.dueDate else { return false }
            return calendar.isDate(date, inSameDayAs: day)
        }
        if !due.isEmpty { lines.append("Due: \(due.map(\.title).joined(separator: ", "))") }
        let overdue = taskManager.tasks.filter { !$0.isCompleted && ($0.dueDate ?? .distantFuture) < Date() }
        if isToday, !overdue.isEmpty {
            lines.append("\(overdue.count) overdue task\(overdue.count == 1 ? "" : "s")")
        }

        let sources = calendarManager.enabledProviderTypes.count
        return ProposedAction(
            kind: .answer,
            title: isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
            details: lines,
            provenance: "Read \(sources) calendar source\(sources == 1 ? "" : "s") · cancelled meetings excluded.",
            run: { _ in "" })
    }

    /// The longest free stretch between the day's meetings — the one you could actually
    /// use for something. Anything under 15 minutes isn't a gap, it's a corridor.
    static func longestGap(_ meetings: [MeetingEvent]) -> (start: Date, length: TimeInterval)? {
        guard meetings.count >= 2 else { return nil }
        var best: (Date, TimeInterval)?
        var cursor = meetings[0].endDate
        for meeting in meetings.dropFirst() {
            let gap = meeting.startDate.timeIntervalSince(cursor)
            if gap > (best?.1 ?? 0) { best = (cursor, gap) }
            cursor = max(cursor, meeting.endDate)
        }
        guard let best, best.1 >= 900 else { return nil }
        return (best.0, best.1)
    }

    /// Meetings that genuinely overlap, named once each.
    static func clashes(_ meetings: [MeetingEvent]) -> [String] {
        var out: [String] = []
        for (index, meeting) in meetings.enumerated() {
            for other in meetings.dropFirst(index + 1) where other.startDate < meeting.endDate {
                let name = "\(meeting.title) / \(other.title)"
                if !out.contains(name) { out.append(name) }
            }
        }
        return out
    }
}

/// Answer an invitation.
struct RSVPTool: AgentTool {
    let name = "rsvp"
    func workingPhrase(_ a: [String: Any]) -> String { "finding that invitation…" }
    let description = "Accept, decline or tentatively accept a meeting invitation, found by its name. Use for 'accept the standup', 'decline the Friday review'."
    var humanSummary: String { "accept or decline an invitation" }
    var parameters: [String: Any] {
        Self.schema([
            "title": Self.string("All or part of the meeting's name"),
            "response": Self.string("One of: accept, decline, tentative")
        ], required: ["title", "response"])
    }

    let calendarManager: CalendarManager

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let needle = ToolArgs.string(arguments, "title") else {
            throw ToolArgumentError(message: "Which meeting?")
        }
        let status: ResponseStatus
        switch ToolArgs.string(arguments, "response")?.lowercased() {
        case "accept", "accepted", "yes": status = .accepted
        case "decline", "declined", "no": status = .declined
        case "tentative", "maybe": status = .tentative
        default: throw ToolArgumentError(message: "Accept, decline, or tentative?")
        }

        let upcoming = calendarManager.upcomingWeek.filter {
            !$0.isCancelled && $0.startDate > Date() && $0.title.localizedCaseInsensitiveContains(needle)
        }
        guard let meeting = upcoming.first else {
            return ProposedAction(kind: .answer, title: "Not found",
                                  details: ["No upcoming meeting called “\(needle)”."],
                                  run: { _ in "" })
        }

        // EventKit offers no RSVP API at all — Apple simply doesn't expose it. Saying so
        // is the only honest option; a button that silently did nothing would be worse
        // than no button.
        guard calendarManager.canRespond(to: meeting) else {
            return ProposedAction(
                kind: .answer,
                title: "Can't reply from here",
                details: ["\(meeting.title) — \(meeting.startDate.formatted(date: .abbreviated, time: .shortened))",
                          "macOS Calendar gives apps no way to RSVP. Microsoft 365 meetings can be answered; this one came from macOS Calendar."],
                provenance: "Nothing was sent.",
                run: { _ in "" })
        }

        let manager = calendarManager
        let verb = status == .accepted ? "Accept" : (status == .declined ? "Decline" : "Tentatively accept")
        // "\(verb)ed" would read "Declineed". Past tense is written out, not derived.
        let past = status == .accepted ? "Accepted" : (status == .declined ? "Declined" : "Tentatively accepted")

        return ProposedAction(
            kind: .change,
            title: "\(verb) invitation",
            details: [meeting.title,
                      meeting.startDate.formatted(date: .abbreviated, time: .shortened),
                      meeting.organizerName.map { "from \($0)" } ?? ""].filter { !$0.isEmpty },
            warnings: status == .declined ? ["The organiser is told you declined"] : [],
            confirmLabel: verb,
            // This one genuinely leaves the Mac — the organiser gets your reply — so it is
            // a tear-out, not a quiet local change.
            tearOut: true,
            run: { _ in
                try await manager.respond(to: meeting.id, status: status)
                return "\(past) “\(meeting.title)”."
            })
    }
}
