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
    /// Image dispatch is not connected yet; its adapter must supply this argument.
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
        for source in sourceEvents {
            guard let title = source["title"] as? String, !title.isEmpty,
                  let start = source["start"] as? String,
                  matches(start, #"^\d{4}-\d{2}-\d{2}(?:T.*)?$"#) else {
                return "An image event needs a complete title and an unambiguous date, including its year."
            }
            let candidates = events.indices.filter { index in
                !matched.contains(index) && (events[index]["title"] as? String) == title &&
                (events[index]["start"] as? String).map { String($0.prefix(10)) == String(start.prefix(10)) } == true
            }
            guard candidates.count == 1, let index = candidates.first else {
                return "The proposal changed or omitted an image event's title or date. Review the extracted events first."
            }
            matched.insert(index)
            if let allDay = source["all_day"] as? Bool {
                guard (events[index]["all_day"] as? Bool) == allDay else {
                    return "The proposal didn't preserve an image event's all-day setting. Nothing has been created."
                }
                if !allDay, (events[index]["start"] as? String) != start {
                    return "The proposal changed the time read from the image. Nothing has been created."
                }
            } else {
                return "Confirm whether the image event is all-day or timed before preparing it."
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

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
var results = [[String:Any]]()
for c in cases {
 let issue = MarginRequestChecks.proposalProblem(tool:c["tool"] as! String, arguments:c["arguments"] as! [String:Any], request:c["request"] as! String, imageEvidence:c["evidence"] as? [String:Any])
 results.append(["id":c["id"]!, "blocked":issue != nil, "reason":issue ?? ""])
}
print(String(data:try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
