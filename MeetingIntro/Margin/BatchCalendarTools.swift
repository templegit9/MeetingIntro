import Foundation

/// Explicit dated lists bypass the model. Every matched date must yield a complete item.
enum DatedEventList {
    static func dateCount(_ text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: #"(?i)(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4}"#)
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    static func arguments(_ text: String) -> [String: Any]? {
        guard text.range(of: #"(?i)\b(calendar|events?)\b"#, options: .regularExpression) != nil,
              text.range(of: #"(?i)\b(put|add|create|schedule)\b"#, options: .regularExpression) != nil else { return nil }
        guard text.range(of: #"(?i)\b\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b"#, options: .regularExpression) == nil else { return nil }
        let pattern = #"(?im)(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),?\s+(\d{4})\s*[–—-]\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count > 1 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d yyyy"; formatter.isLenient = false
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"
        var events: [[String: Any]] = []
        for (i, match) in matches.enumerated() {
            let dateText = (1...3).map { ns.substring(with: match.range(at: $0)) }.joined(separator: " ")
            guard let date = formatter.date(from: dateText) else { return nil }
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let title = ns.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
            guard !title.isEmpty else { return nil }
            events.append(["title": title, "start": iso.string(from: date), "all_day": true])
        }
        return ["events": events]
    }
}

struct CreateEventsTool: AgentTool {
    let name = "create_events"
    let description = "Create MULTIPLE calendar events in one preview. Include EVERY requested event in events, never only the first."
    var humanSummary: String { "prepare a whole list of calendar events, review them together and track each result" }
    let calendarManager: CalendarManager
    let defaultDurationMinutes: Int
    let calendarID: String?
    let jobs: MarginJobStore
    var parameters: [String: Any] {
        Self.schema(["events": ["type": "array", "minItems": 1, "maxItems": 50,
            "items": CreateEventTool(calendarManager: calendarManager, defaultDurationMinutes: defaultDurationMinutes, calendarID: calendarID).parameters]], required: ["events"])
    }
    func workingPhrase(_ a: [String: Any]) -> String { "Validating \((a["events"] as? [Any])?.count ?? 0) events and their destination calendar…" }
    static func validate(_ a: [String: Any], defaultMinutes: Int) throws -> [[String: Any]] {
        guard let events = a["events"] as? [[String: Any]], !events.isEmpty, events.count <= 50 else {
            throw ToolArgumentError(message: "Provide between 1 and 50 complete events. Nothing has been created.")
        }
        var seen: Set<String> = []
        for (i, event) in events.enumerated() {
            guard let title = ToolArgs.string(event, "title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = ToolArgs.date(event, "start") else {
                throw ToolArgumentError(message: "Event \(i + 1) needs a title and a valid date. Nothing has been created.")
            }
            let minutes = ToolArgs.int(event, "duration_minutes") ?? defaultMinutes
            guard minutes > 0 && minutes <= 10080 else { throw ToolArgumentError(message: "Event \(i + 1) has an invalid duration.") }
            guard ToolArgs.strings(event, "attendees").isEmpty, ToolArgs.string(event, "repeat") == nil else {
                throw ToolArgumentError(message: "Batch creation currently supports one-off events without invitees. Prepare invitations or recurring events separately.")
            }
            let key = title.lowercased() + "|" + String(start.timeIntervalSince1970)
            guard seen.insert(key).inserted else { throw ToolArgumentError(message: "The list repeats “\(title)” on the same date. Remove the duplicate before confirming.") }
        }
        return events
    }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        let events = try Self.validate(a, defaultMinutes: defaultDurationMinutes)
        let calendars = await calendarManager.writableCalendarsFromEnabledSources()
        try Task.checkCancellation()
        let candidates = calendars.filter { $0.providerType == calendarManager.eventCreationProvider }
        guard let calendar = calendarID.flatMap({ id in calendars.first { $0.id == id } }) ?? (calendarID == nil ? candidates.first : nil) else {
            throw ToolArgumentError(message: "No writable destination calendar is available. Choose one in calendar settings; nothing has been created.")
        }
        var steps: [MarginJobStore.Step] = []
        var choices: [PageChoice] = []
        for event in events {
            var args = event; args["calendar_id"] = calendar.id; args["provider"] = calendar.providerType.rawValue
            let draft = try Self.draft(event, defaultMinutes: defaultDurationMinutes)
            let step = MarginJobStore.Step(title: draft.title, tool: "create_event", arguments: try JSONSerialization.data(withJSONObject: args, options: .sortedKeys), destination: "\(calendar.name) · \(calendar.source)")
            steps.append(step)
            choices.append(PageChoice(id: step.id.uuidString, label: draft.title, note: CreateEventTool.when(draft)))
        }
        let existing = jobs.jobs.first { job in
            job.state == "awaiting confirmation" && job.steps.count == steps.count &&
            zip(job.steps, steps).allSatisfy { $0.state == "pending" && $0.arguments == $1.arguments && $0.destination == $1.destination }
        }
        let job = existing ?? MarginJobStore.Job(title: "Create \(events.count) calendar events", steps: steps)
        if existing == nil { try jobs.add(job) }
        choices = zip(job.steps, choices).map { step, choice in PageChoice(id: step.id.uuidString, label: choice.label, note: choice.note) }
        return Self.proposal(job, calendarLabel: "\(calendar.name) · \(calendar.source)", jobs: jobs,
                             manager: calendarManager, defaultMinutes: defaultDurationMinutes, choices: choices)
    }
    static func draft(_ event: [String: Any], defaultMinutes: Int) throws -> EventDraft {
        _ = try validate(["events": [event]], defaultMinutes: defaultMinutes)
        let start = ToolArgs.date(event, "start")!
        let allDay = ToolArgs.bool(event, "all_day") ?? false
        let from = allDay ? Calendar.current.startOfDay(for: start) : start
        let end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: from)! : from.addingTimeInterval(Double((ToolArgs.int(event, "duration_minutes") ?? defaultMinutes) * 60))
        var draft = EventDraft(title: ToolArgs.string(event, "title")!, startDate: from, endDate: end, parserUsed: .detector)
        draft.isAllDay = allDay; draft.location = ToolArgs.string(event, "location")
        return draft
    }
    @MainActor static func proposal(_ job: MarginJobStore.Job, calendarLabel: String, jobs: MarginJobStore,
                                    manager: CalendarManager, defaultMinutes: Int, choices: [PageChoice]) -> ProposedAction {
        ProposedAction(kind: .change, title: job.title, details: ["Calendar: \(calendarLabel)", "Select the events to create."],
            groups: [PageGroup(id: "events", label: "\(choices.count) events", choices: choices)],
            provenance: "Each result is saved locally. An uncertain write is never retried automatically. Job \(job.id.uuidString).",
            assumptions: ["Date-only entries are all-day events in \(TimeZone.current.identifier)."],
            warnings: ["No invitations. No automatic undo. Unselected events stay pending; use list_jobs to inspect or resume."],
            confirmLabel: "Create", multipleSelection: true,
            run: { picked in
                let selected = Set((picked ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
                guard !selected.isEmpty else { throw ToolArgumentError(message: "Select at least one event.") }
                let receipt = try await jobs.run(job.id, selected: selected) { step in
                    let args = try JSONSerialization.jsonObject(with: step.arguments) as! [String: Any]
                    let draft = try Self.draft(args, defaultMinutes: defaultMinutes)
                    guard let id = ToolArgs.string(args, "calendar_id"),
                          let provider = CalendarProviderType(rawValue: ToolArgs.string(args, "provider") ?? "") else { throw ToolArgumentError(message: "Destination missing.") }
                    try await manager.createMarginEvent(draft, calendarID: id, providerType: provider)
                    return "Created · \(CreateEventTool.when(draft))"
                }
                guard let updated = jobs.jobs.first(where: { $0.id == job.id }),
                      updated.steps.filter({ selected.contains($0.id) }).allSatisfy({ $0.state == "completed" }) else {
                    throw ToolArgumentError(message: "Some selected events need review. Completed steps will not be repeated.\n" + receipt)
                }
                return receipt
            })
    }
}

/// Conservative checks of explicit user intent before a proposal or memory save.
/// These prevent known failures; they are not a general natural-language parser.
enum MarginRequestChecks {
    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func proposalProblem(tool: String, arguments: [String: Any], request: String, imageEvidence: [String: Any]? = nil) -> String? {
        if tool == "move_event", arguments["new_start"] != nil {
            let preserve = matches(request, #"(?i)\b(same (clock )?time|keep (its |the |their )?time|preserv\w* (the |its )?(clock )?time)\b"#)
            let clock = matches(request, #"(?i)\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\b(noon|midnight)\b"#)
            if preserve || !clock { return "The proposed move supplied a time you didn't ask to change. Please specify the target date; nothing has been changed." }
        }
        guard tool == "create_event" || tool == "create_events" else { return nil }
        let events = tool == "create_events" ? (arguments["events"] as? [[String: Any]] ?? []) : [arguments]
        if let evidence = imageEvidence {
            if let issue = imageCalendarProblem(events: events, evidence: evidence) { return issue }
        }
        let explicitAllDay = matches(request, #"(?i)\b(all[ -]day|whole days?)\b"#)
        // Mixed timed/all-day requests need an explicit review instead of blanket coercion.
        let mixed = matches(request, #"(?i)\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\b(noon|midnight)\b"#)
        if explicitAllDay && !mixed && events.contains(where: { ($0["all_day"] as? Bool) != true }) {
            return "The proposal didn't preserve your all-day instruction. Nothing has been created; please retry the all-day dates."
        }
        let iso = try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#)
        let isoCount = iso.numberOfMatches(in: request, range: NSRange(request.startIndex..., in: request))
        let expected = DatedEventList.dateCount(request) + isoCount
        if expected > events.count { return "The proposal omitted requested dates. Nothing has been created; please retry the complete list." }
        return nil
    }
    /// Called with the reader's complete envelope, never facts stripped of uncertainty.
    /// The agent binds this envelope to the currently attached calendar image.
    static func imageCalendarProblem(events: [[String: Any]], evidence: [String: Any]) -> String? {
        guard let facts = evidence["facts"] as? [String: Any],
              let uncertainties = evidence["uncertainties"] as? [String] else {
            return "The image reading is incomplete. Review the image before preparing calendar events."
        }
        guard uncertainties.isEmpty else {
            return "The image contains unresolved details: \(uncertainties.joined(separator: "; ")). Please clarify them before preparing calendar events."
        }
        // Only an explicit event list supports this direct calendar handoff. Other
        // structures need clarification or a separately validated conversion.
        guard let sourceEvents = facts["events"] as? [[String: Any]], !sourceEvents.isEmpty,
              sourceEvents.count == events.count else {
            return "The proposed events don't match a complete event list from the image. Review the extracted events first."
        }
        var matched = Set<Int>()
        var sourceKeys = Set<String>()
        for source in sourceEvents {
            guard let title = source["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let start = source["start"] as? String,
                  matches(start, #"^\d{4}-\d{2}-\d{2}(?:T.*)?$"#),
                  let allDay = source["all_day"] as? Bool else {
                return "An image event needs its full title, year, date and an explicit all-day or timed setting."
            }
            let day = String(start.prefix(10))
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd"; date.isLenient = false
            guard let parsedDay = date.date(from: day), date.string(from: parsedDay) == day else {
                return "The image contains an invalid calendar date. Please clarify it."
            }
            guard sourceKeys.insert(title + "|" + start + "|" + String(allDay)).inserted else {
                return "The image reading repeats an identical event. Review the list before creating it."
            }
            if !allDay {
                guard matches(start, #"T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#),
                      ISO8601DateFormatter().date(from: start) != nil,
                      let minutes = source["duration_minutes"] as? Int, (1...10080).contains(minutes) else {
                    return "Confirm each timed event's end time and timezone before creating it; no default duration will be assumed."
                }
            } else if let minutes = source["duration_minutes"] as? Int, minutes != 1440 {
                return "Multi-day all-day events need separate review; this import currently supports one day per all-day entry."
            }
            let candidates = events.indices.filter { index in
                !matched.contains(index) && (events[index]["title"] as? String) == title &&
                (events[index]["all_day"] as? Bool) == allDay &&
                (events[index]["start"] as? String).map { allDay ? String($0.prefix(10)) == day : $0 == start } == true
            }
            guard candidates.count == 1, let index = candidates.first else {
                return "The proposal changed, duplicated or omitted an image event's title, date, time or all-day setting. Review the extracted events first."
            }
            matched.insert(index)
            if !allDay, events[index]["duration_minutes"] as? Int != source["duration_minutes"] as? Int {
                return "The proposal changed or omitted an event's duration. Preserve its end time from the image."
            }
            if (events[index]["location"] as? String ?? "") != (source["location"] as? String ?? "") {
                return "The proposal changed or omitted a visible event location."
            }
            if (events[index]["attendees"] != nil && events[index]["attendees"] as? [String] != []) || events[index]["repeat"] != nil {
                return "Screenshot imports create only the visible occurrences, without invitations or new recurring series."
            }
        }
        return nil
    }
    static func canLearn(evidence: String, source: String) -> Bool {
        guard source.contains(evidence) else { return false }
        // Explicitly quoted/fenced material does not establish the user's own preference.
        let quoted = try! NSRegularExpression(pattern: #"(?s)```.*?```|\"[^\"]*\"|“[^”]*”|‘[^’]*’"#)
        let ranges = quoted.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
        let occurrences = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: evidence))
        let ownEvidence = occurrences.matches(in: source, range: NSRange(source.startIndex..., in: source)).contains { match in
            !ranges.contains { NSIntersectionRange($0, match.range).length == match.range.length }
        }
        guard ownEvidence else { return false }
        let thirdParty = matches(source, #"(?i)\b(document quotes|pasted (text|content|customer)|customer review|fictional example|hypothetical example)\b"#)
        let adopted = matches(source, #"(?i)\bI (personally )?(adopt|prefer|want)\b"#)
        return !thirdParty || adopted
    }
}
