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

    /// What to say while this tool is working, given the arguments the model chose —
    /// "looking in Downloads", not "thinking". A wait you can read is a wait you can
    /// judge; a spinner tells you nothing about whether it is doing the right thing.
    func workingPhrase(_ arguments: [String: Any]) -> String

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

    /// Generic fallback, so a new tool is never silent while it works.
    func workingPhrase(_ arguments: [String: Any]) -> String { "working…" }

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
        if let value = args[key] as? Double, value.isFinite, value >= Double(Int.min), value < Double(Int.max), value.rounded(.towardZero) == value { return Int(value) }
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

/// Bounded orchestration. The model chooses the next step; closures that change the world
/// are only invoked by the confirmation handler. Checkpoints are mandatory before proposals.
@MainActor
enum MarginToolLoop {
    enum End { case answered, awaitingApproval, limited }
    @discardableResult
    static func run(messages initial: [[String: Any]], maxRounds: Int = 8,
                    request: ([[String: Any]]) async throws -> OllamaToolClient.Reply,
                    prepare: (OllamaToolClient.ToolCall) async throws -> ProposedAction,
                    checkpoint: ([[String: Any]]) throws -> Void = { _ in },
                    pause: (OllamaToolClient.ToolCall, ProposedAction, [[String: Any]]) throws -> Void = { _, _, _ in },
                    present: (ProposedAction) -> Void,
                    answer: (String) -> Void) async throws -> End {
        var messages = initial
        var seen = Set<String>()
        // A successful read may need refreshing after another tool reports stale evidence.
        // Failed calls remain non-repeatable, and unchanged reads still stop a loop.
        var readGeneration: [String: Int] = [:]
        var errorGeneration = 0
        let deadline = Date().addingTimeInterval(600)
        var steps = 0
        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            try checkpoint(messages)
            let reply = try await request(messages)
            try Task.checkCancellation()
            if reply.toolCalls.isEmpty {
                messages.append(["role": "assistant", "content": reply.text])
                try checkpoint(messages)
                answer(reply.text.isEmpty ? "I couldn't finish this request. No further action was taken." : reply.text)
                return .answered
            }
            // Serialize calls individually. An approval pause never leaves unmatched tool calls
            // in a persisted transcript; the model replans remaining work from actual receipts.
            for call in reply.toolCalls {
                try Task.checkCancellation()
                steps += 1
                guard steps <= 16, Date() < deadline else {
                    answer("I reached this run's limit. No pending action was confirmed.")
                    return .limited
                }
                let data = try JSONSerialization.data(withJSONObject: call.arguments, options: [.sortedKeys])
                let signature = call.name + String(decoding: data, as: UTF8.self)
                let firstAttempt = seen.insert(signature).inserted
                let refreshAfterError = readGeneration[signature].map { $0 < errorGeneration } ?? false
                guard firstAttempt || refreshAfterError else {
                    answer("I reached a repeated step and stopped. No pending action was confirmed.")
                    return .limited
                }
                messages.append(["role": "assistant", "content": "", "tool_calls": [["function": ["name": call.name, "arguments": call.arguments]]]])
                let action: ProposedAction
                do { action = try await prepare(call) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    readGeneration.removeValue(forKey: signature)
                    errorGeneration += 1
                    let result = try JSONSerialization.data(withJSONObject: ["status": "error", "message": error.localizedDescription])
                    messages.append(["role": "tool", "tool_name": call.name, "content": String(decoding: result, as: UTF8.self)])
                    try checkpoint(messages)
                    continue
                }
                try Task.checkCancellation()
                if action.kind == .change || !action.agentReadable {
                    try pause(call, action, messages)
                    present(action)
                    return .awaitingApproval
                }
                let result = try JSONSerialization.data(withJSONObject: action.agentObservation, options: [.sortedKeys])
                guard result.count <= 64_000 else {
                    present(action)
                    answer("This result is too large to carry forward safely. Narrow the search before continuing.")
                    return .limited
                }
                readGeneration[signature] = errorGeneration
                messages.append(["role": "tool", "tool_name": call.name, "content": String(decoding: result, as: UTF8.self)])
                try checkpoint(messages)
                present(action)
            }
        }
        answer("I reached the step limit. You can continue from the results above; no pending action was confirmed.")
        return .limited
    }
}

/// One active goal, with archived records. A crash after execution starts is uncertain:
/// never replay that write automatically, even when no success receipt was saved.
@MainActor
final class MarginRunJournal {
    struct Pending: Codable {
        var tool: String
        var arguments: Data
        var signature: Data
        var choice: String?
        var sourceAttachmentID: UUID? = nil
    }
    struct Record: Codable, Identifiable {
        var id = UUID()
        var goal: String
        var transcript: Data
        var state = "running"
        var pending: Pending?
        var updated = Date()
        var receipts: [String] = []
        var rounds = 0
        var executed: [Pending]? = nil
    }
    private(set) var current: Record?
    private(set) var problem: String?
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingIntro/Margin/active-run.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                current = try JSONDecoder().decode(Record.self, from: Data(contentsOf: self.url))
                if current?.state == "executing" { current?.state = "uncertain" }
                else if current?.state == "running" { current?.state = "interrupted" }
                try persist()
            }
        } catch { problem = "Cannot read the task journal: \(error.localizedDescription)" }
    }
    func start(goal: String, messages: [[String: Any]]) throws {
        guard problem == nil else { throw ToolArgumentError(message: problem!) }
        if let previous = current {
            let archive = url.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(previous).write(to: archive.appendingPathComponent(previous.id.uuidString + ".json"), options: .atomic)
        }
        current = Record(goal: goal, transcript: try JSONSerialization.data(withJSONObject: messages))
        try persist()
    }
    func checkpoint(_ messages: [[String: Any]]) throws {
        guard current != nil else { throw ToolArgumentError(message: "No active task.") }
        let data = try JSONSerialization.data(withJSONObject: messages)
        guard data.count <= 512_000 else { throw ToolArgumentError(message: "This task reached its context limit. Narrow the request to continue.") }
        current?.transcript = data
        try persist()
    }
    func spendRound() throws {
        guard let record = current, record.rounds < 24 else { throw ToolArgumentError(message: "This task reached its total model-call limit.") }
        current?.rounds += 1; try persist()
    }
    func pause(call: OllamaToolClient.ToolCall, action: ProposedAction, messages: [[String: Any]], sourceAttachmentID: UUID? = nil) throws {
        let arguments = try JSONSerialization.data(withJSONObject: call.arguments, options: [.sortedKeys])
        if current?.executed?.contains(where: { $0.tool == call.name && $0.arguments == arguments }) == true {
            throw ToolArgumentError(message: "This task already executed that exact operation. Inspect its receipt instead of repeating it.")
        }
        let archive = url.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
        if FileManager.default.fileExists(atPath: archive.path) {
            for file in try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                if record.id != current?.id, record.state == "uncertain", record.pending?.tool == call.name, record.pending?.arguments == arguments {
                    throw ToolArgumentError(message: "An earlier identical write has an uncertain outcome. Check its destination and resolve that task before retrying.")
                }
            }
        }
        try checkpoint(messages)
        current?.pending = Pending(tool: call.name, arguments: arguments,
                                   signature: try action.approvalSignature(choice: action.defaultChoice), choice: action.defaultChoice, sourceAttachmentID: sourceAttachmentID)
        current?.state = "awaiting confirmation"; try persist()
    }
    func reconcile(wasExecuted: Bool) throws {
        guard current?.state == "uncertain", current?.pending != nil else { throw ToolArgumentError(message: "Only a task with an uncertain write can be reconciled.") }
        if wasExecuted {
            try receipt("User checked the destination and confirmed this operation completed.", success: true, verification: "user_reconciliation")
            try mark("interrupted")
        } else {
            current?.state = "awaiting confirmation"
            try persist()
        }
    }
    func mark(_ state: String) throws { current?.state = state; try persist() }
    func executionStarted(choice: String?, signature: Data) throws {
        guard current?.state == "awaiting confirmation", current?.pending != nil else { throw ToolArgumentError(message: "This approval is no longer active.") }
        current?.pending?.choice = choice; current?.pending?.signature = signature
        current?.state = "executing"; try persist()
    }
    func receipt(_ text: String, success: Bool, verification: String = "tool_execution") throws {
        guard let pending = current?.pending else { throw ToolArgumentError(message: "Missing execution record.") }
        var messages = try transcript()
        let payload: [String: Any] = ["status": success ? "executed" : "uncertain", "result": text, "selected": pending.choice ?? "", "verified_by": verification, "at": ISO8601DateFormatter().string(from: Date())]
        messages.append(["role": "tool", "tool_name": pending.tool, "content": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)])
        current?.receipts.append(text)
        if success {
            let completed = (current?.executed ?? []) + [pending]
            current?.executed = completed
            current?.pending = nil
        }
        current?.state = success ? "running" : "uncertain"
        try checkpoint(messages)
    }
    func recoverableRecords() throws -> [Record] {
        var records = current.map { [$0] } ?? []
        let archive = url.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
        if FileManager.default.fileExists(atPath: archive.path) {
            for file in try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                if record.id != current?.id { records.append(record) }
            }
        }
        return records.filter { ["interrupted", "running", "awaiting confirmation", "uncertain", "executing"].contains($0.state) }.sorted { $0.updated > $1.updated }
    }
    func activate(_ id: UUID) throws {
        if current?.id == id { return }
        guard let record = try recoverableRecords().first(where: { $0.id == id }) else { throw ToolArgumentError(message: "That saved task is no longer available.") }
        let archive = url.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
        if let current {
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(current).write(to: archive.appendingPathComponent(current.id.uuidString + ".json"), options: .atomic)
        }
        current = record
        if current?.state == "executing" { current?.state = "uncertain" }
        else if current?.state == "running" { current?.state = "interrupted" }
        try persist()
    }
    func transcript() throws -> [[String: Any]] {
        guard let data = current?.transcript, let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ToolArgumentError(message: "Task context is unavailable.") }
        return value
    }
    private func persist() throws {
        guard problem == nil else { throw ToolArgumentError(message: problem!) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            current?.updated = Date()
            if let current { try JSONEncoder().encode(current).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        } catch { problem = "Cannot save task progress: \(error.localizedDescription)"; throw error }
    }
}
