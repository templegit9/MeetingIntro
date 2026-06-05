import Foundation

/// A speaker-agnostic transcription result — the pipeline assigns You/Them based
/// on which exported track the audio came from.
struct RawTranscriptSegment {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// One audio file in → timestamped segments out. Implementations: WhisperKit
/// (on-device) and Groq (online).
protocol TranscriptionEngine {
    /// Human-readable name for job-state display ("WhisperKit · base", "Groq · whisper-large-v3-turbo").
    var displayName: String { get }
    func transcribe(_ audioURL: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [RawTranscriptSegment]
}

enum TranscriptionError: LocalizedError {
    case missingKey
    case http(Int, detail: String)
    case badResponse(String)
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Groq API key set — add one under Settings → Recording → Transcription, or switch to the offline engine."
        case .http(let code, let detail):
            let hint = code == 401 ? " (bad API key?)" : code == 413 ? " (file too large)" : code == 429 ? " (rate-limited)" : ""
            return "Groq returned HTTP \(code)\(hint)\(detail.isEmpty ? "" : " — \(detail)")"
        case .badResponse(let detail):
            return "Unexpected transcription response: \(detail)"
        case .engineFailure(let detail):
            return detail
        }
    }
}

// MARK: - Groq (online)

/// Whisper-large-v3-turbo via Groq's OpenAI-compatible audio endpoint.
/// ~30 seconds per hour of audio; free-tier friendly. The exported mono 32 kbps
/// tracks keep an hour of audio ≈ 14 MB, under the 25 MB upload cap.
struct GroqWhisperEngine: TranscriptionEngine {
    let apiKey: String
    var displayName: String { "Groq · whisper-large-v3-turbo" }

    func transcribe(_ audioURL: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [RawTranscriptSegment] {
        guard !apiKey.isEmpty else { throw TranscriptionError.missingKey }
        await progress("Uploading to Groq…")

        let boundary = "meetingintro-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3-turbo")
        field("response_format", "verbose_json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.badResponse("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = root["error"] as? [String: Any], let msg = err["message"] as? String {
                detail = msg
            }
            throw TranscriptionError.http(http.statusCode, detail: detail)
        }

        await progress("Parsing transcript…")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = root["segments"] as? [[String: Any]] else {
            throw TranscriptionError.badResponse("verbose_json missing segments")
        }
        return segments.compactMap { seg in
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { return nil }
            return RawTranscriptSegment(start: start, end: end, text: text)
        }
    }
}
