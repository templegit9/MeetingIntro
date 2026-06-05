import Foundation
import UserNotifications
import AVFoundation

/// Manages macOS system notifications for meeting countdowns.
@MainActor
final class NotificationManager: ObservableObject {

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled") }
    }

    /// Whether a cancellation fires an immediate system notification. When off,
    /// cancellations are still tracked (struck-through rows, dropdown badge,
    /// reminder suppression) — just silently. Jon's doc flagged this toggle as a
    /// recommended enhancement.
    @Published var cancellationNotifyEnabled: Bool {
        didSet { UserDefaults.standard.set(cancellationNotifyEnabled, forKey: "cancellationNotifyEnabled") }
    }

    /// Whether the Mixkit sound plays alongside a cancellation notification.
    /// "You have one less meeting" arguably doesn't warrant the same fanfare
    /// as "your meeting starts in 2 minutes."
    @Published var cancellationPlaySound: Bool {
        didSet { UserDefaults.standard.set(cancellationPlaySound, forKey: "cancellationPlaySound") }
    }

    /// Reference to Mixkit sound manager for custom alert sounds.
    var soundManager: MixkitSoundManager?

    private var sentNotificationKeys: Set<String> = []
    private var audioPlayer: AVAudioPlayer?

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.cancellationNotifyEnabled = d.object(forKey: "cancellationNotifyEnabled") as? Bool ?? true
        self.cancellationPlaySound = d.object(forKey: "cancellationPlaySound") as? Bool ?? true
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

    /// Post a one-shot notification when a meeting is detected as cancelled.
    /// Keyed per meeting; dedup against UNUserNotificationCenter.
    /// Gated on both the global toggle and the cancellation-specific one —
    /// when either is off, the caller still marks the cancellation as seen so the
    /// dropdown badge and suppression behavior work, just silently.
    func sendCancellationNotification(for meeting: MeetingEvent) {
        guard isEnabled, cancellationNotifyEnabled else { return }
        let key = "cancellation_\(meeting.id)"
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Meeting cancelled"
        content.subtitle = meeting.title
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        var bodyParts: [String] = ["was \(formatter.string(from: meeting.startDate))"]
        if let organizer = meeting.organizerName, !organizer.isEmpty {
            bodyParts.append("· \(organizer)")
        }
        content.body = bodyParts.joined(separator: " ")
        content.sound = cancellationPlaySound ? .default : nil

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }

        // Also play the user's Mixkit sound if they've selected one.
        if cancellationPlaySound {
            playSelectedSound()
        }
    }

    /// Post a notification when a recording's transcript + notes are ready.
    func sendNotesReadyNotification(title: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting notes ready"
        content.subtitle = title
        content.body = "Open Meeting Notes from the menu bar to read the summary, decisions, and action items."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "notes_ready_\(title)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Post a one-shot notification when an auto-recording starts. Keyed per meeting
    /// so a brief sleep/wake (which produces a new recording file for the same meeting)
    /// doesn't double-notify within the same calendar event.
    func sendRecordingStartedNotification(for meeting: MeetingEvent) {
        guard isEnabled else { return }
        let key = "recording_started_\(meeting.id)"
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Recording started"
        content.subtitle = meeting.title
        content.body = "Audio is being captured to ~/Movies/MeetingIntro/. Click the menu bar icon to stop."
        content.sound = .default

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
