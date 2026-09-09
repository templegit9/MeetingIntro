import Foundation

/// The honesty gate for Margin's routing.
///
/// A local model's tool choice is not a thing you reason about — it is a thing you
/// measure, and it changes whenever the model, the prompt or a tool description changes.
/// So the utterances that have actually gone wrong live here as fixtures, in the same
/// spirit as `FileOrganizer.runSelfTest`.
///
/// Run it headless against the configured model:
/// ```
/// MARGIN_FIXTURES=1 /Applications/MeetingIntro.app/Contents/MacOS/MeetingIntro
/// ```
/// Every case below is either a real misfire that was reported or fixed (a question about
/// abilities that called `find_time`; "move my 3pm to 4pm" answered by **creating a second
/// meeting**) or a boundary that must keep holding — the destructive ask, the request for
/// something not in the registry, the name that must never become an invitation.
enum MarginFixtures {

    struct Case {
        let utterance: String
        /// nil means: it must call no tool and say what it can't do.
        let expected: String?
        let note: String
    }

    static let cases: [Case] = [
        .init(utterance: "lunch with Sam tomorrow 1pm", expected: "create_event",
              note: "must not stall asking for Sam's email"),
        .init(utterance: "remind me to submit the expense report by Friday 5pm", expected: "create_task",
              note: "deadline task"),
        .init(utterance: "add a task to buy milk", expected: "create_task",
              note: "must not refuse for want of a deadline"),
        .init(utterance: "what's on today?", expected: "whats_on_today", note: "read"),
        .init(utterance: "when am I free for 30 minutes", expected: "find_time", note: "read"),
        .init(utterance: "what's free tomorrow afternoon", expected: "find_time",
              note: "needs from_date + an hour range to be answerable"),
        .init(utterance: "any gaps this week for a 45 minute call", expected: "find_time", note: "phrasing"),
        .init(utterance: "block 90 minutes for the board deck on Thursday", expected: "create_event", note: "hold"),
        .init(utterance: "all day for Labour Day", expected: "create_event", note: "all-day"),
        .init(utterance: "what can yo do", expected: "list_capabilities",
              note: "REPORTED: this called find_time before list_capabilities existed"),
        .init(utterance: "what can you do?", expected: "list_capabilities", note: "abilities"),
        .init(utterance: "help", expected: "list_capabilities", note: "abilities"),
        .init(utterance: "who are you", expected: "list_capabilities", note: "abilities"),
        .init(utterance: "move my 3pm to 4pm", expected: nil,
              note: "MUST decline — it once created a second meeting at 4pm instead"),
        .init(utterance: "cancel my 2pm", expected: nil, note: "must decline, not built"),
        .init(utterance: "delete everything in Downloads", expected: nil, note: "destructive"),
        .init(utterance: "how is the weather in Lagos", expected: nil, note: "not in the registry")
    ]

    /// Runs every case against the live registry and prints a report. Returns true when
    /// all of them pass.
    @MainActor @discardableResult
    static func run(agent: MarginAgent, config: MarginConfig) async -> Bool {
        print("Margin fixtures · \(config.model) · \(cases.count) cases")
        switch await OllamaToolClient.status(baseURL: config.baseURL, model: config.model) {
        case .failure(let error):
            print("  cannot run: \(error.localizedDescription)")
            return false
        case .success: break
        }

        var passed = 0
        for testCase in cases {
            let started = Date()
            let called = await agent.routeForTesting(testCase.utterance)
            let elapsed = Date().timeIntervalSince(started)
            let ok = called == testCase.expected
            if ok { passed += 1 }
            let mark = ok ? "✓" : "✗"
            print(String(format: "  %@ %5.1fs  %-18@ %@", mark, elapsed,
                         called ?? "(declined)", testCase.utterance))
            if !ok { print("        expected \(testCase.expected ?? "(declined)") — \(testCase.note)") }
        }
        print("  \(passed)/\(cases.count) correct")
        return passed == cases.count
    }
}
