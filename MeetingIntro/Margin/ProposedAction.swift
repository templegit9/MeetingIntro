import Foundation

/// One selectable line on a page — a slot, an option, a candidate.
///
/// **Fix 2 of the design review lives here.** An answer you can't act on makes the
/// assistant a search box: six lines of text and no way to choose or send anything. A
/// choice carries its own note, so the page shows the thing you would otherwise have to
/// work out for yourself.
struct PageChoice: Identifiable, Equatable {
    enum Tone: Equatable {
        case normal
        /// The recommendation. Pre-selected, and it says why.
        case best
        /// Possible, but something is off about it.
        case caution
    }
    let id: String
    /// The line itself — "09:00".
    let label: String
    /// What you'd otherwise have to work out — "end of a 5-hour stretch".
    var note: String?
    var tone: Tone = .normal
}

/// Choices under a heading — a day, a category.
struct PageGroup: Identifiable, Equatable {
    let id: String
    let label: String
    var choices: [PageChoice]
}

/// What Margin is about to do, or what it found, in a form you can read and act on.
///
/// The rule the design review states plainly: **every page ends in at most two actions and
/// says why it says what it says.** If a page has neither, it isn't finished.
struct ProposedAction: Identifiable {
    enum Kind {
        /// Answers a question. It may still carry choices and an action — an answer is
        /// not the same as a dead end.
        case answer
        /// Changes something. Always confirmed first.
        case change
    }

    let id = UUID()
    let kind: Kind
    /// Uppercase kicker at the top of the page — "30 MIN", "CREATE EVENT".
    let title: String
    /// Plain lines, for pages that have nothing to choose between.
    var details: [String] = []
    /// Selectable lines, grouped. Fix 5: grouped and ranked, never six flat rows.
    var groups: [PageGroup] = []
    /// Fix 4: which calendars were read, over what range, in whose timezone. Every answer
    /// carries its evidence, and it is the line that makes the answer checkable.
    var provenance: String?
    /// Anything invented to fill a gap — the same contract Quick Add has.
    var sources: [PageSource] = []
    var assumptions: [String] = []
    var warnings: [String] = []
    /// Read evidence may return to the agent; optional UI actions are never executed by the loop.
    var agentReadable: Bool = false
    var confirmLabel: String = "Do it"
    /// True when confirming sends something to another person — an invitation, a reply.
    /// Only those get "Tear out & send": the page physically leaves the pad.
    var multipleSelection: Bool = false
    var tearOut: Bool = false
    /// The one alternative. Two actions is the ceiling.
    var secondary: (label: String, run: @MainActor (String?) async throws -> String)?
    /// Performs the change, given the chosen line's id when there is one.
    let run: @MainActor (String?) async throws -> String
    var undo: (@MainActor () async throws -> Void)?

    /// The pre-selected line: the recommendation, or the first.
    var defaultChoice: String? {
        if multipleSelection { return groups.flatMap(\.choices).map(\.id).joined(separator: ",") }
        return groups.flatMap(\.choices).first { $0.tone == .best }?.id
            ?? groups.flatMap(\.choices).first?.id
    }

    static func answer(_ title: String, _ details: [String]) -> ProposedAction {
        ProposedAction(kind: .answer, title: title, details: details, agentReadable: true, run: { _ in title })
    }
}

/// One turn in the conversation.
struct AssistantTurn: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var action: ProposedAction?
    /// Which line is selected on this page.
    var picked: String?
    var outcome: String?
    var performed: Bool = false
    var undone: Bool = false
}

/// A line on today's page.
struct MarginTick: Identifiable {
    let id = UUID()
    let text: String
    let at: Date
    let undo: (@MainActor () async throws -> Void)?
    var crossed = false

    /// One hour, from the spec. After that it is history, not a decision.
    var crossable: Bool { undo != nil && !crossed && Date().timeIntervalSince(at) < 3600 }
}


extension AssistantTurn {
    /// Tool results must be visible to the model; an empty assistant message loses the thread.
    var contextText: String {
        var parts = [text]
        if let action {
            parts += [action.title] + action.details
            parts += action.groups.flatMap { $0.choices.map { $0.label } }
            parts += action.warnings
            if outcome == nil { parts.append(action.kind == .change || !action.agentReadable ? "Proposal only; not confirmed." : "Read observation; no write executed.") }
        }
        for source in action?.sources ?? [] { parts.append("[\(source.id)] \(source.title): \(source.url.absoluteString)") }
        if let outcome { parts.append(outcome) }
        return String(parts.filter { !$0.isEmpty }.joined(separator: "\n").prefix(4000))
    }
}

/// Stable, data-only contract shared by the agent transcript and approval journal.
extension ProposedAction {
    var agentObservation: [String: Any] {
        ["status": kind == .change ? "proposal" : "observation", "title": title,
         "details": details, "warnings": warnings, "assumptions": assumptions,
         "provenance": provenance ?? "",
         "groups": groups.map { group in ["label": group.label, "choices": group.choices.map {
             ["id": $0.id, "label": $0.label, "note": $0.note ?? ""]
         }] },
         "sources": sources.map { ["id": $0.id, "title": $0.title, "url": $0.url.absoluteString] },
         "confirmation": confirmLabel, "multiple_selection": multipleSelection]
    }
    func approvalSignature(choice: String?) throws -> Data {
        var value = agentObservation
        value["selection"] = choice ?? ""
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
