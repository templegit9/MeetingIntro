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

    /// Diagnostic log — injected in AppLifecycleManager.observe. Optional so the
    /// manager stays usable standalone.
    var diagnosticLog: DiagnosticLog?

    /// Live system authorization status. Surfaced in Diagnostics + the Sounds tab
    /// so a denied permission (which silently kills every notification) is visible.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var notificationsAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private var sentNotificationKeys: Set<String> = []
    private var audioPlayer: AVAudioPlayer?

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        self.cancellationNotifyEnabled = d.object(forKey: "cancellationNotifyEnabled") as? Bool ?? true
        self.cancellationPlaySound = d.object(forKey: "cancellationPlaySound") as? Bool ?? true
    }

    /// Request notification permission and capture the result. Also refreshes the
    /// stored status (so a permission revoked in System Settings is reflected on
    /// next launch).
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error {
                    self.diagnosticLog?.error(.notification, "Authorization request failed: \(error.localizedDescription)")
                } else {
                    self.diagnosticLog?.info(.notification, "Authorization request returned granted=\(granted)")
                }
                self.refreshAuthorizationStatus()
            }
        }
    }

    /// Re-read the system authorization status into `authorizationStatus`.
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.authorizationStatus
                self.authorizationStatus = settings.authorizationStatus
                if previous != settings.authorizationStatus {
                    self.diagnosticLog?.info(.notification, "Authorization status = \(Self.describe(settings.authorizationStatus))")
                }
            }
        }
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Send a notification for a countdown trigger.
    func sendCountdownNotification(for meeting: MeetingEvent, minutesBefore: Int) {
        guard isEnabled else {
            diagnosticLog?.info(.notification, "Countdown notification suppressed (notifications disabled in app) — \(meeting.title) @ \(minutesBefore)m")
            return
        }
        if !notificationsAuthorized {
            diagnosticLog?.warn(.notification, "Countdown notification will likely not appear — system authorization is \(Self.describe(authorizationStatus)) — \(meeting.title)")
        }

        let key = "\(meeting.id)_\(minutesBefore)"
        guard !sentNotificationKeys.contains(key) else {
            diagnosticLog?.debug(.notification, "Countdown notification suppressed (dedup \(key))")
            return
        }
        sentNotificationKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Meeting in \(minutesBefore) minute\(minutesBefore == 1 ? "" : "s")"
        content.subtitle = meeting.title
        if let location = meeting.location, !location.isEmpty {
            content.body = "📍 \(location)"
        }
        content.sound = .default
        content.categoryIdentifier = "MEETING_COUNTDOWN"

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        deliver(request, describing: "countdown \(minutesBefore)m — \(meeting.title)")

        // Also play the selected Mixkit sound if available
        playSelectedSound()
    }

    /// Submit a request to UNUserNotificationCenter and log the system result.
    private func deliver(_ request: UNNotificationRequest, describing what: String) {
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error = error {
                    self?.diagnosticLog?.error(.notification, "Delivery failed (\(what)): \(error.localizedDescription)")
                } else {
                    self?.diagnosticLog?.info(.notification, "Notification sent — \(what)")
                }
            }
        }
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
        guard isEnabled, cancellationNotifyEnabled else {
            diagnosticLog?.info(.cancellation, "Cancellation notification suppressed (\(isEnabled ? "cancellation toggle off" : "notifications disabled)")) — \(meeting.title)")
            return
        }
        if !notificationsAuthorized {
            diagnosticLog?.warn(.cancellation, "Cancellation notification will likely not appear — system authorization is \(Self.describe(authorizationStatus))")
        }
        let key = "cancellation_\(meeting.id)"
        guard !sentNotificationKeys.contains(key) else {
            diagnosticLog?.debug(.cancellation, "Cancellation notification suppressed (dedup \(key))")
            return
        }
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
        deliver(request, describing: "cancellation — \(meeting.title)")

        // Also play the user's Mixkit sound if they've selected one.
        if cancellationPlaySound {
            playSelectedSound()
        }
    }

    /// Post a notification when a recording's transcript + notes are ready.
    func sendNotesReadyNotification(title: String) {
        guard isEnabled else {
            diagnosticLog?.info(.notes, "Notes-ready notification suppressed (notifications disabled) — \(title)")
            return
        }
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
        deliver(request, describing: "notes ready — \(title)")
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
        deliver(request, describing: "recording started — \(meeting.title)")
    }

    // MARK: - Auto-join ("Start at Time", Issue #2)

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Confirmation that a meeting has been armed for auto-join.
    func sendAutoJoinArmedNotification(for meeting: MeetingEvent) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Auto-join armed"
        content.subtitle = meeting.title
        content.body = "MeetingIntro will open this meeting at \(Self.timeString(meeting.startDate)). Disarm from the menu bar."
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "autojoin_armed_\(meeting.id)_\(Date().timeIntervalSince1970)",
            content: content, trigger: nil
        )
        deliver(request, describing: "auto-join armed — \(meeting.title)")
    }

    /// Posted the moment an armed meeting's link is opened automatically.
    func sendAutoJoinFiredNotification(for meeting: MeetingEvent) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Joining meeting"
        content.subtitle = meeting.title
        content.body = "Opening the meeting link now."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "autojoin_fired_\(meeting.id)",
            content: content, trigger: nil
        )
        deliver(request, describing: "auto-join fired — \(meeting.title)")
    }

    /// Posted when an armed meeting's start passed beyond the freshness window (e.g. the
    /// Mac slept through it) — the link was deliberately NOT opened.
    func sendAutoJoinMissedNotification(for meeting: MeetingEvent) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Missed auto-join"
        content.subtitle = meeting.title
        content.body = "This meeting started while you were away, so it wasn't opened automatically."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "autojoin_missed_\(meeting.id)",
            content: content, trigger: nil
        )
        deliver(request, describing: "auto-join missed — \(meeting.title)")
    }
}
