import Combine
import Foundation

/// Serial queue turning finished recordings into transcripts + notes:
/// split tracks → transcribe each (You/Them) → merge → transcript.md →
/// LLM notes → notes.md → notification.
///
/// Job state is published per recording path for the viewer and Settings.
/// Failures surface verbatim — no silent engine fallback (a surprise 1.6 GB
/// model download is not a fallback; a misconfigured key should say so).
@MainActor
final class MeetingNotesPipeline: ObservableObject {

    enum JobState: Equatable {
        case queued
        case running(String)          // human-readable stage
        case done
        case failed(String)
    }

    @Published private(set) var jobs: [String: JobState] = [:]   // key: audio file path

    private let notesConfig: MeetingNotesConfig
    private let quickAddConfig: QuickAddConfig
    var notificationManager: NotificationManager?

    private var queue: [RecordingDocument] = []
    private var isProcessing = false

    init(notesConfig: MeetingNotesConfig, quickAddConfig: QuickAddConfig) {
        self.notesConfig = notesConfig
        self.quickAddConfig = quickAddConfig
    }

    func state(for document: RecordingDocument) -> JobState? {
        jobs[document.id]
    }

    /// Enqueue a recording. No-ops if it's already queued or running.
    func enqueue(_ document: RecordingDocument) {
        switch jobs[document.id] {
        case .queued, .running: return
        default: break
        }
        jobs[document.id] = .queued
        queue.append(document)
        processNextIfIdle()
    }

    /// Auto-trigger entry point for the recording coordinator.
    func enqueueIfAutoEnabled(audioURL: URL) {
        guard notesConfig.autoGenerate else { return }
        enqueue(RecordingDocument(audioURL: audioURL))
    }

    private func processNextIfIdle() {
        guard !isProcessing, !queue.isEmpty else { return }
        isProcessing = true
        let document = queue.removeFirst()
        Task { @MainActor in
            await process(document)
            isProcessing = false
            processNextIfIdle()
        }
    }

    private func process(_ document: RecordingDocument) async {
        let setStage: @MainActor (String) -> Void = { [weak self] stage in
            self?.jobs[document.id] = .running(stage)
        }
        do {
            // 1. Split the dual-track recording into per-speaker mono files.
            setStage("Splitting audio tracks…")
            let tracks = try await AudioTrackExporter.split(document.audioURL)
            defer {
                if let url = tracks.them { try? FileManager.default.removeItem(at: url) }
                if let url = tracks.me { try? FileManager.default.removeItem(at: url) }
            }

            // 2. Transcribe each side with the selected engine.
            let engine = notesConfig.makeEngine()
            var segments: [TranscriptSegment] = []
            if let themURL = tracks.them {
                setStage("Transcribing meeting audio (\(engine.displayName))…")
                let raw = try await engine.transcribe(themURL) { stage in setStage("Them: \(stage)") }
                segments += raw.map { TranscriptSegment(start: $0.start, end: $0.end, speaker: .them, text: $0.text) }
            }
            if let meURL = tracks.me {
                setStage("Transcribing your microphone (\(engine.displayName))…")
                let raw = try await engine.transcribe(meURL) { stage in setStage("You: \(stage)") }
                segments += raw.map { TranscriptSegment(start: $0.start, end: $0.end, speaker: .me, text: $0.text) }
            }
            guard !segments.isEmpty else {
                throw TranscriptionError.engineFailure("Transcription produced no speech segments — was the recording silent?")
            }

            // 3. Merge + write the transcript sidecar.
            setStage("Writing transcript…")
            let transcriptBody = segments.renderedMarkdown()
            let transcriptDoc = "# Transcript — \(document.displayTitle)\n\n" + transcriptBody + "\n"
            try transcriptDoc.write(to: document.transcriptURL, atomically: true, encoding: .utf8)

            // 4. Generate + write the notes sidecar.
            setStage("Generating notes (\(quickAddConfig.modelID))…")
            let notes = try await NotesGenerator.generate(
                transcriptMarkdown: transcriptBody,
                meetingTitle: document.displayTitle,
                meetingDate: document.displayDate,
                config: quickAddConfig
            )
            try notes.write(to: document.notesURL, atomically: true, encoding: .utf8)

            jobs[document.id] = .done
            notificationManager?.sendNotesReadyNotification(title: document.displayTitle)
        } catch {
            jobs[document.id] = .failed(error.localizedDescription)
        }
    }
}
