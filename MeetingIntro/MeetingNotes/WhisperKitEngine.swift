import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit (CoreML / Neural Engine). Fully private —
/// audio never leaves the Mac. The model is downloaded by WhisperKit to
/// Application Support on first use (~150 MB for base, ~1.6 GB for
/// large-v3_turbo) and cached thereafter.
///
/// The WhisperKit instance is cached per model name: initialization (model load)
/// takes seconds and shouldn't be repaid per track.
final class WhisperKitEngine: TranscriptionEngine {

    let modelName: String
    var displayName: String { "WhisperKit · \(modelName)" }

    /// One shared instance cache across the app — keyed by model name.
    private static var cached: (model: String, kit: WhisperKit)?
    private static let cacheLock = NSLock()

    init(modelName: String) {
        self.modelName = modelName
    }

    func transcribe(_ audioURL: URL, progress: @escaping @MainActor (String) -> Void) async throws -> [RawTranscriptSegment] {
        let kit = try await Self.kit(for: modelName, progress: progress)

        await progress("Transcribing on-device (\(modelName))…")
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioPath: audioURL.path)
        } catch {
            throw TranscriptionError.engineFailure("WhisperKit transcription failed: \(error.localizedDescription)")
        }

        return results.flatMap { result in
            result.segments.map { seg in
                RawTranscriptSegment(
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    // WhisperKit segment text carries special tokens like <|0.00|>; strip them.
                    text: seg.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                )
            }
        }
    }

    private static func kit(for model: String, progress: @escaping @MainActor (String) -> Void) async throws -> WhisperKit {
        cacheLock.lock()
        if let cached, cached.model == model {
            let kit = cached.kit
            cacheLock.unlock()
            return kit
        }
        cacheLock.unlock()

        await progress("Loading model \(model) (downloads on first use)…")
        let kit: WhisperKit
        do {
            kit = try await WhisperKit(WhisperKitConfig(model: model))
        } catch {
            throw TranscriptionError.engineFailure(
                "Couldn't load WhisperKit model \"\(model)\": \(error.localizedDescription). Check the model name in Settings → Recording, or pick a smaller model."
            )
        }
        cacheLock.lock()
        cached = (model, kit)
        cacheLock.unlock()
        return kit
    }
}
