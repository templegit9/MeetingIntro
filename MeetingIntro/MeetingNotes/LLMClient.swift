import Foundation

/// Minimal OpenAI-compatible chat-completions client for long-form work
/// (meeting notes). Deliberately separate from OpenRouterParser's request path:
/// the parser is tuned for a 6-second live-parse window with parse-specific
/// error hints and was heavily field-debugged — not worth destabilizing for
/// ~30 lines of shared HTTP. This client uses long timeouts and generic errors.
enum LLMClient {

    enum LLMError: LocalizedError {
        case invalidBaseURL(String)
        case timeout(TimeInterval)
        case network(String)
        case http(Int, detail: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL(let url): return "Invalid API base URL: \(url)"
            case .timeout(let secs): return "The AI provider didn't respond within \(Int(secs))s."
            case .network(let detail): return "Network error: \(detail)"
            case .http(let code, let detail):
                let hint = code == 401 ? " (bad API key?)" : code == 429 ? " (rate-limited)" : code == 404 ? " (unknown model?)" : ""
                return "AI provider returned HTTP \(code)\(hint)\(detail.isEmpty ? "" : " — \(detail)")"
            case .emptyResponse: return "The AI provider returned an empty response."
            }
        }
    }

    /// Send a system+user message pair, return the assistant's text content.
    static func complete(
        system: String,
        user: String,
        baseURL: String,
        key: String,
        model: String,
        timeout: TimeInterval = 120
    ) async throws -> String {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let endpoint = URL(string: trimmedBase + "/chat/completions"), endpoint.scheme != nil else {
            throw LLMError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as? URLError)?.code == .timedOut { throw LLMError.timeout(timeout) }
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var detail = ""
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
                detail = msg
            }
            throw LLMError.http(code, detail: detail)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }
}
