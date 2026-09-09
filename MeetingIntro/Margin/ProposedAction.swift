import Foundation

/// What the assistant is about to do, in a form the user can read and approve.
///
/// The whole safety model of the plugin is that the model's output stops here. Nothing
/// in this type executes; `run` is only called after an explicit confirmation, and
/// `undo` exists for anything that isn't purely a read.
struct ProposedAction: Identifiable {
    enum Kind {
        /// Answers a question. Nothing to confirm — there is nothing to undo about
        /// reading your own calendar, so these present as an answer, not a card.
        case answer
        /// Changes something. Always confirmed first.
        case change
    }

    let id = UUID()
    let kind: Kind
    /// Verb + object, e.g. "Create event". Reads as a button label.
    let title: String
    /// The specifics, one line each: "Tue 8 Sep, 1:00 PM – 1:30 PM", "Personal · Google".
    var details: [String]
    /// Anything invented to fill a gap — the same contract Quick Add has. A guess that
    /// isn't shown is a guess that lands on the calendar unnoticed.
    var assumptions: [String] = []
    /// Reasons to look twice: an overlap, invitees that can't be invited on this
    /// calendar, a folder with a lot of files.
    var warnings: [String] = []
    /// Label for the confirm button. "Create", "Move", "Organize".
    var confirmLabel: String = "Do it"
    /// True when confirming sends something to another person — an invitation, a reply.
    /// Only those get "Tear out & send": the page physically leaves the pad, which is
    /// what sending means. A private calendar write stays in the notebook.
    var tearOut: Bool = false
    /// Performs the change. Returns the sentence shown afterwards.
    let run: @MainActor () async throws -> String
    /// Reverses it, when that is possible. Nil means there is nothing to undo (a read),
    /// or the action cannot be taken back — which the UI says out loud.
    var undo: (@MainActor () async throws -> Void)?

    static func answer(_ title: String, _ details: [String]) -> ProposedAction {
        ProposedAction(kind: .answer, title: title, details: details, run: { title })
    }
}

/// One turn in the conversation.
struct AssistantTurn: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// Attached to an assistant turn when it proposed something.
    var action: ProposedAction?
    /// Set once the user has acted on the proposal, so a card can't be run twice.
    var outcome: String?
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
