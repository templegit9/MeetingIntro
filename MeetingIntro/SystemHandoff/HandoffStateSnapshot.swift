import CoreAudio
import Foundation

/// Captures the system state we changed when a meeting started, so we can put it back
/// when the meeting ends. Persisted to UserDefaults so an app crash mid-meeting still
/// leaves a recovery path on next launch.
///
/// We store the *UID* (a stable string identifier) for the prior output device rather
/// than the `AudioDeviceID` (which is reassigned by CoreAudio on disconnect/reconnect).
struct HandoffStateSnapshot: Codable, Equatable {
    let meetingID: String
    let endTime: Date
    let priorOutputDeviceUID: String?
    let priorFocusWasActive: Bool

    static let userDefaultsKey = "handoffStateSnapshot"

    static func load() -> HandoffStateSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(HandoffStateSnapshot.self, from: data)
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
