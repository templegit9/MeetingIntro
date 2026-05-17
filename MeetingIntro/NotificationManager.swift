import Foundation
import UserNotifications
import AVFoundation

/// Manages macOS system notifications for meeting countdowns.
@MainActor
final class NotificationManager: ObservableObject {

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled") }
    }

    /// Reference to Mixkit sound manager for custom alert sounds.
    var soundManager: MixkitSoundManager?

    private var sentNotificationKeys: Set<String> = []
    private var audioPlayer: AVAudioPlayer?

    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
    }

    /// Request notification permission from the user.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    /// Send a notification for a countdown trigger.
    func sendCountdownNotification(for meeting: MeetingEvent, minutesBefore: Int) {
        guard isEnabled else { return }

        let key = "\(meeting.id)_\(minutesBefore)"
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Meeting in \(minutesBefore) minute\(minutesBefore == 1 ? "" : "s")"
        content.subtitle = meeting.title
        if let location = meeting.location, !location.isEmpty {
            content.body = "📍 \(location)"
        }
        content.sound = .default
        content.categoryIdentifier = "MEETING_COUNTDOWN"

        let request = UNNotificationRequest(
            identifier: key,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to deliver notification: \(error.localizedDescription)")
            }
        }

        // Also play the selected Mixkit sound if available
        playSelectedSound()
    }

    /// Play the currently selected Mixkit notification sound.
    private func playSelectedSound() {
        guard let url = soundManager?.selectedSoundURL() else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Failed to play notification sound: \(error)")
        }
    }

    /// Reset sent state (e.g., daily or on provider switch).
    func resetSentState() {
        sentNotificationKeys.removeAll()
    }
}
