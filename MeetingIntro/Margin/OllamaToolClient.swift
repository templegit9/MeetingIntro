import Foundation

/// Talks to a local Ollama for tool calling.
///
/// Deliberately **not** `LLMClient`: that one is a one-shot text completion for meeting
/// notes with generic errors, tuned for a 120-second job. This is a multi-turn loop that
/// has to carry a tool registry, read `tool_calls` back, and — most importantly — say
/// precisely why it can't work, because "Ollama isn't running" and "that model isn't
/// pulled" and "this model has no tool support" are three different problems with three
/// different fixes, and a menu-bar assistant that answers "I can't do that" to all three
/// is useless. (`gemma3:4b` answers HTTP 400 to a tools request; measured, not assumed.)
enum OllamaToolClient {

    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    struct Reply {
        var text: String
        var toolCalls: [ToolCall]
    }

    enum ClientError: LocalizedError {
        case notRunning
        case modelMissing(String)
        case noToolSupport(String)
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "Ollama isn't running. Start it (or `brew services start ollama`) and try again."
            case .modelMissing(let model):
                return "The model “\(model)” isn't installed. Run `ollama pull \(model)` in Terminal."
            case .noToolSupport(let model):
                return "“\(model)” can't call tools, so it can't act on your behalf. Try gpt-oss:20b or gemma4:e4b."
            case .http(let code, let detail):
                return "Ollama returned HTTP \(code). \(detail)"
            case .badResponse:
                return "Ollama sent a reply this app couldn't read."
            }
        }
    }

    /// Is a local Ollama answering, and does it have this model?
    static func status(baseURL: String, model: String) async -> Result<Void, ClientError> {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags") else {
            return .failure(.notRunning)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return .failure(.badResponse) }
            let names = models.compactMap { $0["name"] as? String }
            // Ollama reports "gpt-oss:20b"; a user may have typed "gpt-oss".
            let installed = names.contains { $0 == model || $0.hasPrefix(model + ":") }
            return installed ? .success(()) : .failure(.modelMissing(model))
        } catch {
            return .failure(.notRunning)
        }
    }

    /// One turn. `messages` is the running transcript in OpenAI shape.
    static func chat(baseURL: String,
                     model: String,
                     messages: [[String: Any]],
                     tools: [[String: Any]],
                     timeout: TimeInterval = 120) async throws -> Reply {
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/api/chat") else { throw ClientError.notRunning }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "tools": tools,
            "messages": messages,
            // Zero temperature: this is intent classification, not writing. Measured at
            // 12/12 on the fixture set; sampling only adds ways to be wrong.
            "options": ["temperature": 0]
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.notRunning
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            if status == 400, detail.lowercased().contains("tool") { throw ClientError.noToolSupport(model) }
            if status == 404 { throw ClientError.modelMissing(model) }
            throw ClientError.http(status, String(detail.prefix(200)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { throw ClientError.badResponse }

        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            // Arguments arrive as an object from Ollama, but as a JSON string from some
            // OpenAI-compatible servers. Accept both.
            if let object = function["arguments"] as? [String: Any] {
                return ToolCall(name: name, arguments: object)
            }
            if let text = function["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                return ToolCall(name: name, arguments: parsed)
            }
            return ToolCall(name: name, arguments: [:])
        }
        return Reply(text: (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                     toolCalls: calls)
    }
}
