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
            provenance: "Available from the current tool registry. Changes require a preview and your confirmation.",
            run: { _ in "" })
    }
}

/// Dictionary reads bypass model inference, but remain ordinary notebook receipts.
struct DefineWordTool: AgentTool {
    let name = "define_word"
    let description = "Look up a word or phrase: meaning, examples and synonyms. Unknown words return spelling suggestions."
    var humanSummary: String { "define words and suggest spelling corrections" }
    var parameters: [String: Any] { Self.schema(["word": Self.string("Word or short phrase to define")], required: ["word"]) }
    func workingPhrase(_ arguments: [String: Any]) -> String { "looking up \(ToolArgs.string(arguments, "word") ?? "the word")…" }

    static func requestedWord(_ prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:define\s+|meaning of\s+|what does\s+)(.+?)(?:\s+mean)?[?!.]?$"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            let matched = String(text[range])
            let word = matched.replacingOccurrences(of: #"(?i)^(define\s+|meaning of\s+|what does\s+)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(\s+mean)?[?!.]?$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return word.isEmpty ? nil : word
        }
        let commands: Set<String> = ["help", "cancel", "stop", "undo", "yes", "no", "continue", "thanks", "hello", "hi", "settings", "history", "index"]
        if !commands.contains(text.lowercased()), text.range(of: #"^[\p{L}][\p{L}'’-]{1,59}$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    static func lines(_ entries: [WordEntry]) -> [String] {
        var result: [String] = []
        for entry in entries {
            result.append(entry.word + (entry.phonetic.map { " · " + $0 } ?? ""))
            for meaning in entry.meanings {
                if !meaning.partOfSpeech.isEmpty { result.append(meaning.partOfSpeech) }
                for definition in meaning.definitions.prefix(6) {
                    result.append(definition.text)
                    if let example = definition.example { result.append("Example: " + example) }
                }
                if !meaning.synonyms.isEmpty { result.append("Synonyms: " + meaning.synonyms.prefix(10).joined(separator: ", ")) }
            }
        }
        return result
    }

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let word = ToolArgs.string(arguments, "word"), word.count <= 160 else {
            throw ToolArgumentError(message: "Give me a word or short phrase to define.")
        }
        do {
            let entries = try await DictionaryService.lookup(word, preferOffline: true)
            return ProposedAction(kind: .answer, title: word, details: Self.lines(entries),
                                  provenance: entries.first?.sourceNote ?? "Dictionary API · dictionaryapi.dev", run: { _ in "" })
        } catch {
            let suggestions = DictionaryService.suggestions(for: word)
            guard !suggestions.isEmpty else {
                return .answer("No definition found", [error.localizedDescription, "Check the spelling, or try ‘define’ followed by the word."])
            }
            return ProposedAction(kind: .answer, title: "Did you mean…?", details: ["I couldn't find a definition for “\(word)”. Choose a spelling to look up."],
                groups: [.init(id: "spelling", label: "Spelling suggestions", choices: suggestions.map { .init(id: $0, label: $0) })],
                provenance: "Spelling suggestions from macOS. Nothing has been substituted automatically.", confirmLabel: "Look up", run: { selection in
                    guard let selection, suggestions.contains(selection) else { throw ToolArgumentError(message: "Choose a spelling first.") }
                    return Self.lines(try await DictionaryService.lookup(selection, preferOffline: true)).joined(separator: "\n\n")
                })
        }
    }
}
