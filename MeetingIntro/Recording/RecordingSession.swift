import Foundation

/// Snapshot of an in-progress recording, persisted to UserDefaults so that an app
/// crash mid-recording leaves a recovery path on next launch.
///
/// On launch, if a snapshot exists and `meetingEndTime <= now`, the recovery flow
/// attempts to finalize the file via `AVAssetWriter.finishWriting()`. If that fails
/// (the writer's internal state is gone), the partial file is deleted. Either way
/// the snapshot is cleared.
struct RecordingSession: Codable, Equatable {
    let meetingID: String
    let meetingTitle: String
    let fileURL: URL
    let startedAt: Date
    let meetingEndTime: Date

    static let userDefaultsKey = "recordingSession"

    static func load() -> RecordingSession? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(RecordingSession.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
