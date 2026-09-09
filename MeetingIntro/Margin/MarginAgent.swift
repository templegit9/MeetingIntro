import Foundation

/// The conversation loop: what you say → one tool call → a proposal you confirm.
///
/// **It is a command bar with a face, not a chatbot.** A model this size is decent at
/// intent-to-arguments and bad at open conversation, so every turn aims at an action
/// card. Two measured facts shaped this:
///
/// 1. Telling the model to **assume rather than ask** took the fixture set from 10/12 to
///    12/12 and cut the worst case from 28.2s to 12.7s. Without that line it refuses
///    "lunch with Sam tomorrow 1pm" wanting Sam's email — the same instinct the app's
///    assumptions contract exists to overrule.
/// 2. It **declines cleanly** when nothing fits: weather, "move my 3pm" (not built yet),
///    and "delete everything in Downloads" were all refused rather than mapped onto a
///    tool that happened to be nearby.
@MainActor
final class MarginAgent: ObservableObject {

    @Published private(set) var turns: [AssistantTurn] = []
    @Published private(set) var isThinking = false
    /// Set when the local model can't be reached, with the fix in the message. Three
    /// different problems (not running / not pulled / no tool support) must not collapse
    /// into one shrug.
    @Published var problem: String?

    private let config: MarginConfig
    private var tools: [AgentTool] = []
    var diagnosticLog: DiagnosticLog?

    init(config: MarginConfig) {
        self.config = config
    }

    func register(_ tools: [AgentTool]) { self.tools = tools }

    var toolNames: [String] { tools.map(\.name) }

    /// Person-facing summary of the registry, for the capabilities answer. Derived, so a
    /// new tool shows up here the moment it is registered.
    var capabilities: [String] {
        tools.filter { !($0 is CapabilitiesTool) }.map(\.humanSummary)
    }

    /// Instructions. The date has to be stated: a local model has no clock, and every
    /// "tomorrow" depends on it.
    private var systemPrompt: String {
        let now = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
        return """
        You are MeetingIntro's assistant, running on the user's own Mac. Right now it is \(now) \
        in the local timezone.

        Call exactly one tool when the request matches one. If no tool fits, reply in one short \
        sentence saying what you cannot do. Never invent a tool.

        NEVER ask the user for missing details and never refuse for want of them. Fill any gap with \
        a sensible default and call the tool anyway — the app shows the user a preview to confirm or \
        correct before anything is saved.

        Only invite people whose email address the user actually typed. Never guess an address from \
        a name. Keep every reply to one or two sentences.

        If the user asks what you can do, what you are, or for help, call list_capabilities. Never \
        answer a question about your abilities by calling a tool that does something else.

        You cannot move, reschedule, cancel or delete anything that already exists. If asked to, say \
        so plainly — NEVER create a new event instead, as that would leave the user with two.
        """
    }

    func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isThinking else { return }
        turns.append(AssistantTurn(role: .user, text: prompt))
        isThinking = true
        problem = nil
        defer { isThinking = false }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        // Carry the recent conversation so "no, tomorrow instead" works. Bounded: a
        // local model's context is small and every extra token is latency.
        for turn in turns.suffix(8) {
            messages.append(["role": turn.role == .user ? "user" : "assistant", "content": turn.text])
        }

        let started = Date()
        do {
            let reply = try await OllamaToolClient.chat(
                baseURL: config.baseURL, model: config.model,
                messages: messages, tools: tools.map(\.wireFormat),
                timeout: TimeInterval(config.timeoutSeconds))
            let elapsed = Date().timeIntervalSince(started)

            guard let call = reply.toolCalls.first else {
                // No tool: the model is declining, which is a legitimate outcome.
                turns.append(AssistantTurn(role: .assistant,
                                           text: reply.text.isEmpty ? "I can't help with that one." : reply.text))
                diagnosticLog?.info(.assistant, "EA: no tool for \"\(prompt)\" (\(String(format: "%.1f", elapsed))s)")
                return
            }
            guard let tool = tools.first(where: { $0.name == call.name }) else {
                // A hallucinated tool name. Say so plainly rather than pretending.
                turns.append(AssistantTurn(role: .assistant, text: "I can't do that yet."))
                diagnosticLog?.warn(.assistant, "EA: model asked for unknown tool \"\(call.name)\"")
                return
            }
            do {
                let action = try await tool.prepare(call.arguments)
                var turn = AssistantTurn(role: .assistant, text: "")
                turn.action = action
                turn.picked = action.defaultChoice
                turns.append(turn)
                diagnosticLog?.info(.assistant, "EA: \(call.name) proposed for \"\(prompt)\" (\(String(format: "%.1f", elapsed))s)")
            } catch {
                turns.append(AssistantTurn(role: .assistant, text: error.localizedDescription))
                diagnosticLog?.warn(.assistant, "EA: \(call.name) arguments rejected — \(error.localizedDescription)")
            }
        } catch {
            problem = error.localizedDescription
            diagnosticLog?.warn(.assistant, "EA: \(error.localizedDescription)")
        }
    }

    /// Run a proposal. Only ever called from an explicit confirmation.
    func confirm(_ turnID: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let action = turns[index].action, turns[index].outcome == nil else { return }
        do {
            let result = try await action.run(turns[index].picked)
            turns[index].outcome = result
            recordTick(result, undo: action.undo)
            diagnosticLog?.info(.assistant, "EA: \(action.title) — \(result)")
        } catch {
            turns[index].outcome = "Couldn't do it: \(error.localizedDescription)"
            diagnosticLog?.error(.assistant, "EA: \(action.title) failed — \(error.localizedDescription)")
        }
    }

    func undo(_ turnID: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let undo = turns[index].action?.undo, turns[index].outcome != nil else { return }
        do {
            try await undo()
            turns[index].undone = true
            turns[index].outcome = "Undone."
            diagnosticLog?.info(.assistant, "EA: undone")
        } catch {
            turns[index].outcome = "Couldn't undo: \(error.localizedDescription)"
        }
    }

    /// The alternative action on a page. Two is the ceiling, so there is only ever this
    /// one besides the primary.
    func runSecondary(_ turnID: UUID) async {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              let secondary = turns[index].action?.secondary, turns[index].outcome == nil else { return }
        do {
            let result = try await secondary.run(turns[index].picked)
            turns[index].outcome = result
            recordTick(result, undo: turns[index].action?.undo)
        } catch {
            turns[index].outcome = "Couldn't do it: \(error.localizedDescription)"
        }
    }

    /// Pick a line on a page.
    func pick(_ turnID: UUID, choice: String) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].picked = choice
    }

    func dismissProposal(_ turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].outcome = "Dismissed."
    }

    func clear() { turns.removeAll(); problem = nil }

    /// Today's page: what Margin actually did, in the order it did it.
    ///
    /// A silent action that leaves no receipt is the failure mode the whole spec is
    /// arranged against — capability must never outrun the record.
    @Published private(set) var ticks: [MarginTick] = []

    /// Record something done — by a confirmed page, or by a folded corner you accepted.
    func recordTick(_ text: String, undo: (@MainActor () async throws -> Void)?) {
        ticks.append(MarginTick(text: text, at: Date(), undo: undo))
    }

    /// Cross a tick back out. Only within the hour: past that the world has moved on and
    /// pretending otherwise would be a lie about what can be taken back.
    func crossOut(_ id: UUID) async {
        guard let index = ticks.firstIndex(where: { $0.id == id }),
              ticks[index].crossable, let undo = ticks[index].undo else { return }
        do {
            try await undo()
            ticks[index].crossed = true
        } catch {
            diagnosticLog?.warn(.assistant, "Margin: couldn't cross out — \(error.localizedDescription)")
        }
    }

    /// Which tool the model picks for an utterance, without preparing or running
    /// anything. Exists for `MarginFixtures` — routing is measured, not assumed.
    func routeForTesting(_ prompt: String) async -> String? {
        let messages: [[String: Any]] = [["role": "system", "content": systemPrompt],
                                         ["role": "user", "content": prompt]]
        let reply = try? await OllamaToolClient.chat(
            baseURL: config.baseURL, model: config.model,
            messages: messages, tools: tools.map(\.wireFormat),
            timeout: TimeInterval(config.timeoutSeconds))
        return reply?.toolCalls.first?.name
    }

    /// Check the local model before the user types into a dead box.
    func checkAvailability() async {
        switch await OllamaToolClient.status(baseURL: config.baseURL, model: config.model) {
        case .success: problem = nil
        case .failure(let error): problem = error.localizedDescription
        }
    }
}
