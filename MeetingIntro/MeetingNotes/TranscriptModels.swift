import Foundation

/// One attributed, timestamped utterance in a meeting transcript.
struct TranscriptSegment: Equatable {
    enum Speaker: String {
        case me = "You"
        case them = "Them"
    }

    let start: TimeInterval
    let end: TimeInterval
    let speaker: Speaker
    let text: String
}

extension Array where Element == TranscriptSegment {
    /// Merge two per-track transcripts into one chronological conversation and
    /// render as markdown. Consecutive segments from the same speaker within a
    /// short gap are coalesced into one block for readability.
    func renderedMarkdown() -> String {
        let sorted = self.sorted { $0.start < $1.start }
        var lines: [String] = []
        var currentSpeaker: TranscriptSegment.Speaker?
        var currentStart: TimeInterval = 0
        var currentText: [String] = []
        var lastEnd: TimeInterval = 0

        func flush() {
            guard let speaker = currentSpeaker, !currentText.isEmpty else { return }
            lines.append("**[\(Self.timestamp(currentStart))] \(speaker.rawValue):** \(currentText.joined(separator: " "))")
            currentText = []
        }

        for segment in sorted {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Coalesce same-speaker segments separated by < 3s of silence.
            if segment.speaker == currentSpeaker && segment.start - lastEnd < 3 {
                currentText.append(trimmed)
            } else {
                flush()
                currentSpeaker = segment.speaker
                currentStart = segment.start
                currentText = [trimmed]
            }
            lastEnd = segment.end
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    static func timestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// A recording on disk plus its derived sidecar state. The `.m4a` is the source;
/// `<name>.transcript.md` and `<name>.notes.md` siblings are the durable outputs.
struct RecordingDocument: Identifiable, Equatable {
    let audioURL: URL

    var id: String { audioURL.path }
    var baseName: String { audioURL.deletingPathExtension().lastPathComponent }
    var transcriptURL: URL { audioURL.deletingPathExtension().appendingPathExtension("transcript.md") }
    var notesURL: URL { audioURL.deletingPathExtension().appendingPathExtension("notes.md") }

    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }
    var hasNotes: Bool { FileManager.default.fileExists(atPath: notesURL.path) }

    /// Parse "YYYY-MM-DD HHmm - Title" back into display parts. Falls back to the
    /// raw filename for anything that doesn't match the recorder's pattern.
    var displayTitle: String {
        let parts = baseName.components(separatedBy: " - ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : baseName
    }

    var displayDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let prefix = baseName.components(separatedBy: " - ").first ?? ""
        return formatter.date(from: prefix)
    }

    /// All recordings in a directory, newest first.
    static func scan(directory: URL) -> [RecordingDocument] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map(RecordingDocument.init(audioURL:))
            .sorted { ($0.displayDate ?? .distantPast) > ($1.displayDate ?? .distantPast) }
    }
}
