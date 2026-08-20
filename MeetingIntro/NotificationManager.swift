import AppKit
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

    /// Whether to fire a system notification at the moment a meeting starts (T-0),
    /// in addition to the pre-meeting countdown reminders. Default on.
    @Published var notifyAtStartEnabled: Bool {
        didSet { UserDefaults.standard.set(notifyAtStartEnabled, forKey: "notifyAtStartEnabled") }
    }

    /// Whether to notify when a meeting's start time is moved (Issue #5). Default on.
    @Published var timeChangeNotifyEnabled: Bool {
        didSet { UserDefaults.standard.set(timeChangeNotifyEnabled, forKey: "timeChangeNotifyEnabled") }
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
        self.notifyAtStartEnabled = d.object(forKey: "notifyAtStartEnabled") as? Bool ?? true
        self.timeChangeNotifyEnabled = d.object(forKey: "timeChangeNotifyEnabled") as? Bool ?? true
    }

    /// Request notification permission and capture the result. Also refreshes the
    /// stored status (so a permission revoked in System Settings is reflected on
    /// next launch).
    /// Notification category + action identifiers for task-due reminders (Issue #19).
    static let taskDueCategory = "TASK_DUE"
    static let taskDoneAction = "TASK_DONE"
    static let taskSnoozeAction = "TASK_SNOOZE"

    /// Register the task-due action buttons ("Mark done" / "Snooze"). Called once at launch.
    func registerTaskCategory() {
        let done = UNNotificationAction(identifier: Self.taskDoneAction, title: "Mark done", options: [])
        let snooze = UNNotificationAction(identifier: Self.taskSnoozeAction, title: "Snooze 10 min", options: [])
        let category = UNNotificationCategory(identifier: Self.taskDueCategory, actions: [done, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestPermission() {
        registerTaskCategory()
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
    /// "Close the camera flap if it's open." Deliberately conditional — the app cannot
    /// see a physical cover, so it never claims your camera is exposed.
    ///
    /// Carries its own distinct sound (a short system click, not the meeting-reminder
    /// sound) so it's identifiable without reading it: different meaning, different noise.
    /// We play it ourselves and leave `content.sound` nil, so the banner can't double up
    /// with the default alert.
    func sendCameraCoverNotification(title: String, subtitle: String, isTest: Bool = false) {
        guard isEnabled || isTest else {
            diagnosticLog?.info(.notification, "Camera-cover reminder suppressed (notifications disabled in app)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = isTest ? "\(subtitle)  ·  Test" : subtitle
        content.sound = nil
        content.categoryIdentifier = "CAMERA_COVER"

        let key = "camera_cover_\(Int(Date().timeIntervalSince1970))"
        deliver(UNNotificationRequest(identifier: key, content: content, trigger: nil),
                describing: isTest ? "camera-cover reminder (test)" : "camera-cover reminder")
        playCameraCoverSound()
    }

    /// A short, dry click — the closest thing macOS ships to a shutter, and distinct from
    /// every other sound the app makes. Falls back to the standard alert if the system
    /// sound is ever missing.
    func playCameraCoverSound() {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            diagnosticLog?.warn(.notification, "Camera-cover sound failed: \(error.localizedDescription)")
        }
    }

    /// One banner for several meetings that start together, instead of N banners landing
    /// on top of each other. Marks each meeting's own dedup key as sent, so a later poll
    /// can't follow up with the individual notifications this replaced.
    func sendGroupedCountdownNotification(for meetings: [MeetingEvent], minutesBefore: Int) {
        guard let first = meetings.first else { return }
        guard meetings.count > 1 else {
            sendCountdownNotification(for: first, minutesBefore: minutesBefore)
            return
        }
        guard isEnabled else {
            diagnosticLog?.info(.notification, "Grouped countdown notification suppressed (notifications disabled in app) — \(meetings.count) meetings")
            return
        }

        let ids = meetings.map(\.id).sorted().joined(separator: "|")
        let key = "group_\(minutesBefore)_\(ids.hashValue)"
        guard !sentNotificationKeys.contains(key) else {
            diagnosticLog?.debug(.notification, "Grouped countdown notification suppressed (dedup \(key))")
            return
        }
        sentNotificationKeys.insert(key)
        // Claim the per-meeting keys too — otherwise the next poll would deliver the
        // individual notifications this banner stands in for.
        for meeting in meetings { sentNotificationKeys.insert("\(meeting.id)_\(minutesBefore)") }

        let content = UNMutableNotificationContent()
        content.title = "\(meetings.count) meetings in \(minutesBefore) minute\(minutesBefore == 1 ? "" : "s")"
        content.subtitle = "at \(first.formattedStartTime)"
        let names = meetings.prefix(2).map(\.title).joined(separator: ", ")
        let extra = meetings.count - min(2, meetings.count)
        content.body = extra > 0 ? "\(names), +\(extra) more" : names
        content.sound = .default
        content.categoryIdentifier = "MEETING_COUNTDOWN"
        content.threadIdentifier = "clash_\(Int(first.startDate.timeIntervalSince1970))"

        deliver(UNNotificationRequest(identifier: key, content: content, trigger: nil),
                describing: "grouped countdown \(minutesBefore)m — \(meetings.count) meetings")
        playSelectedSound()
    }

    /// Several armed meetings came due at once and we opened only one of them — say so,
    /// naming what was left closed, so the choice is never silent.
    func sendAutoJoinClashNotification(opened: MeetingEvent, skipped: [MeetingEvent]) {
        guard isEnabled, !skipped.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Opened \(opened.title)"
        content.subtitle = skipped.count == 1
            ? "1 other meeting started at the same time"
            : "\(skipped.count) other meetings started at the same time"
        content.body = skipped.map(\.title).joined(separator: ", ")
        content.sound = .default
        content.categoryIdentifier = "MEETING_COUNTDOWN"
        let key = "autojoin_clash_\(opened.id)_\(Int(opened.startDate.timeIntervalSince1970))"
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)
        deliver(UNNotificationRequest(identifier: key, content: content, trigger: nil),
                describing: "auto-join clash — opened \(opened.title), skipped \(skipped.count)")
    }

    func sendCountdownNotification(for meeting: MeetingEvent, minutesBefore: Int, threadID: String? = nil) {
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
        // Shared thread → macOS stacks the clash into one group in Notification Center
        // instead of three separate entries (ConcurrentNotificationStyle.threaded).
        if let threadID { content.threadIdentifier = threadID }

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

    /// Notify that a meeting was rescheduled to a new start time (Issue #5). Dedup is
    /// handled upstream in `CalendarManager` (keyed by id + new start), so the same move
    /// only reaches here once.
    func sendTimeChangeNotification(for meeting: MeetingEvent, from previousStart: Date) {
        guard isEnabled, timeChangeNotifyEnabled else {
            diagnosticLog?.info(.calendar, "Time-change notification suppressed (\(isEnabled ? "time-change toggle off" : "notifications disabled")) — \(meeting.title)")
            return
        }
        if !notificationsAuthorized {
            diagnosticLog?.warn(.calendar, "Time-change notification will likely not appear — system authorization is \(Self.describe(authorizationStatus))")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDate(previousStart, inSameDayAs: meeting.startDate) ? .none : .medium
        formatter.timeStyle = .short

        let content = UNMutableNotificationContent()
        content.title = "Meeting moved"
        content.subtitle = meeting.title
        content.body = "Now \(formatter.string(from: meeting.startDate)) (was \(formatter.string(from: previousStart)))"
        content.sound = .default

        // Unique per move so a later reschedule of the same meeting isn't coalesced.
        let key = "timechange_\(meeting.id)_\(Int(meeting.startDate.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        deliver(request, describing: "time change — \(meeting.title)")
        playSelectedSound()
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

    // MARK: - Meeting start

    /// One-shot notification fired the moment a meeting starts (T-0). De-duped per
    /// meeting so the 30s poll / a brief sleep-wake can't repeat it. Caller gates on
    /// freshness (only genuinely-starting meetings), armed-state, and RSVP.
    func sendMeetingStartedNotification(for meeting: MeetingEvent) {
        guard isEnabled, notifyAtStartEnabled else {
            diagnosticLog?.info(.notification, "Meeting-start notification suppressed (\(isEnabled ? "start toggle off" : "notifications disabled")) — \(meeting.title)")
            return
        }
        let key = "started_\(meeting.id)"
        guard !sentNotificationKeys.contains(key) else { return }
        sentNotificationKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = "Meeting starting now"
        content.subtitle = meeting.title
        if meeting.url != nil {
            content.body = "It's time — open the meeting to join."
        } else if let location = meeting.location, !location.isEmpty {
            content.body = location
        } else {
            content.body = "It's time for your meeting."
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        deliver(request, describing: "meeting started — \(meeting.title)")
    }

    /// A task's deadline reminder (Issue #19). Dedup is enforced upstream by
    /// `TaskReminderCoordinator`; the `isEnabled` gate + delivery mirror the meeting path.
    func sendTaskDueNotification(for task: TaskItem) {
        guard isEnabled else {
            diagnosticLog?.info(.notification, "Task-due notification suppressed (notifications disabled) — \(task.title)")
            return
        }
        if !notificationsAuthorized {
            diagnosticLog?.warn(.notification, "Task-due notification will likely not appear — system authorization is \(Self.describe(authorizationStatus)) — \(task.title)")
        }
        let content = UNMutableNotificationContent()
        let dueSuffix = task.dueLabel.isEmpty ? "" : " — due \(task.dueLabel)"
        content.title = "Task due"
        content.subtitle = task.title
        content.body = task.remindLeadMinutes > 0 ? "Coming up\(dueSuffix)" : "It's time\(dueSuffix)"
        content.sound = .default
        // "Mark done" / "Snooze 10 min" action buttons (handled in AppDelegate).
        content.categoryIdentifier = Self.taskDueCategory
        content.userInfo = ["taskID": task.id]

        let key = "task_\(task.id)_\(Int((task.dueDate ?? Date()).timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        deliver(request, describing: "task due — \(task.title)")
        playSelectedSound()
    }

    // MARK: - Executive Assistant (Issue #17, v2.13.0)

    /// An automated organize run needs review — nothing has moved yet.
    func sendAssistantReviewNotification(folder: String, count: Int) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Files ready to organize"
        content.body = "\(count) file\(count == 1 ? "" : "s") in \(folder) — open Executive Assistant to review."
        content.sound = .default
        let key = "assistant_review_\(folder)"
        deliver(UNNotificationRequest(identifier: key, content: content, trigger: nil), describing: "assistant review — \(folder)")
        playSelectedSound()
    }

    /// An automated organize run applied changes (auto-apply on) — undo is available.
    func sendAssistantOrganizedNotification(folder: String, count: Int) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Organized \(count) file\(count == 1 ? "" : "s")"
        content.body = "in \(folder). Undo is available in Executive Assistant."
        content.sound = .default
        let key = "assistant_organized_\(folder)_\(Int(Date().timeIntervalSince1970))"
        deliver(UNNotificationRequest(identifier: key, content: content, trigger: nil), describing: "assistant organized — \(folder)")
        playSelectedSound()
    }
}
