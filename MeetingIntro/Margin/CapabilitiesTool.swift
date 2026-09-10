import Foundation

/// Answers "what can you do?".
///
/// It exists because of a real misfire: asked *"what can yo do"*, the model called
/// `find_time`. With nothing in the registry that fits, a tool-calling model reaches for
/// the nearest tool rather than declining — so the honest fix is to give the question a
/// tool of its own rather than to hope the prompt talks it out of guessing.
///
/// The list is **generated from the live registry**, so it cannot drift: a tool that is
/// added and not mentioned here would be a lie the first time someone asked.
struct CapabilitiesTool: AgentTool {
    let name = "list_capabilities"
    func workingPhrase(_ a: [String: Any]) -> String { "checking what I can do…" }
    let description = "Answer what you are able to do. Use for 'what can you do', 'help', 'what do you do'."
    var humanSummary: String { "tell you what I can do" }
    var parameters: [String: Any] { Self.schema([:]) }

    /// Supplied at wiring time so this reads the registry rather than a hardcoded list.
    let summaries: @MainActor () -> [String]

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let lines = summaries()
        return ProposedAction(
            kind: .answer,
            title: "What I can do",
            details: lines.isEmpty ? ["Nothing is wired up yet."] : lines.map { "· \($0)" },
            provenance: "Everything here runs on this Mac. Nothing is saved until you say so.",
            run: { _ in "" })
    }
}
