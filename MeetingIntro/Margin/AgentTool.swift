import Foundation

/// One thing the Executive Assistant can do.
///
/// **Every tool proposes; nothing executes on its own.** `prepare` turns the model's
/// arguments into a `ProposedAction` the user sees and confirms — the same
/// preview-then-confirm shape as Quick Add's draft and File Organizer's dry run. A local
/// model at this size will eventually invent an argument, and the preview is what makes
/// that harmless rather than destructive.
///
/// The registry deliberately contains **no destructive verb**. File Organizer's rule
/// holds here too: move and create, never delete.
protocol AgentTool: Sendable {
    /// Name the model calls. Snake case, because that is what tool-calling models are
    /// trained on.
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments, as the OpenAI/Ollama tool format expects.
    var parameters: [String: Any] { get }

    /// How this reads to a person when Margin is asked what it can do. Separate from
    /// `description`, which is written for the model — the two audiences want different
    /// sentences, and conflating them makes one of them worse.
    var humanSummary: String { get }

    /// Turn model arguments into something the user can read and approve. Throwing here
    /// is normal — a missing or nonsense argument becomes a plain sentence, never a
    /// silent no-op.
    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction
}

extension AgentTool {
    /// Falls back to the model-facing text rather than forcing every tool to write two.
    var humanSummary: String { description }

    /// The tool as Ollama's `/api/chat` wants it.
    var wireFormat: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parameters]]
    }

    /// Schema helper — a plain object schema, since that is what every tool here needs.
    static func schema(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    static func stringArray(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }
}

/// Argument reading that says what was wrong rather than defaulting silently.
enum ToolArgs {
    static func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? Double { return Int(value) }
        if let text = args[key] as? String { return Int(text) }
        return nil
    }
    static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let value = args[key] as? Bool { return value }
        if let text = args[key] as? String { return ["true", "yes", "1"].contains(text.lowercased()) }
        return nil
    }
    static func strings(_ args: [String: Any], _ key: String) -> [String] {
        if let list = args[key] as? [String] { return list }
        if let text = args[key] as? String, !text.isEmpty {
            return text.split(whereSeparator: { ",; ".contains($0) }).map(String.init)
        }
        return []
    }

    /// Dates arrive as the model's idea of ISO 8601, which is close but not reliable —
    /// missing seconds, a space instead of a T, a trailing Z on a local time. Parse
    /// generously, then let the preview show what was understood.
    static func date(_ args: [String: Any], _ key: String) -> Date? {
        guard let text = (args[key] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
                        [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Raised when arguments can't be made sense of. The message is shown to the user, so it
/// is written for them, not for a log.
struct ToolArgumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
