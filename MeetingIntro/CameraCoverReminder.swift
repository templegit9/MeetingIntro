import Combine
import Foundation

/// Settings for the camera-cover reminder. **Off by default** — it's for people who use a
/// physical camera cover, and it's noise for everyone else.
@MainActor
final class CameraCoverConfig: ObservableObject {

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "cameraCoverReminderEnabled") }
    }

    /// How long after a meeting ends (or the camera goes quiet) to nudge. Immediately is
    /// too soon — you're still saying goodbye.
    @Published var delayMinutes: Int {
        didSet { UserDefaults.standard.set(delayMinutes, forKey: "cameraCoverDelayMinutes") }
    }

    /// Stay quiet if the next meeting starts within this many minutes: you're not closing
    /// the cover for a 6-minute gap, and a nudge you'll ignore is how a reminder becomes
    /// something you switch off.
    @Published var skipIfNextMeetingWithinMinutes: Int {
        didSet { UserDefaults.standard.set(skipIfNextMeetingWithinMinutes, forKey: "cameraCoverSkipWithinMinutes") }
    }

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: "cameraCoverReminderEnabled") as? Bool ?? false
        self.delayMinutes = d.object(forKey: "cameraCoverDelayMinutes") as? Int ?? 2
        self.skipIfNextMeetingWithinMinutes = d.object(forKey: "cameraCoverSkipWithinMinutes") as? Int ?? 10
    }
}

/// Reminds you to close a physical camera cover once you're out of a meeting.
///
/// **What it does NOT do:** look through your camera. The app cannot see whether your
/// cover is open — there is no API for a piece of plastic, and taking a frame to check
/// would light the green LED and need camera permission. So this reminds ("close the
/// camera flap if it's open") rather than reports ("your camera is exposed"). The copy is
/// deliberately conditional; don't "improve" it into a claim we can't back.
///
/// **When it fires:** `delayMinutes` after either a meeting ends or the camera stops being
/// used, provided all of these hold at that moment —
///   1. no meeting is currently running (the call ran past its scheduled end),
///   2. the camera isn't in use (you're still on an unscheduled call),
///   3. the next meeting isn't within `skipIfNextMeetingWithinMinutes`.
///
/// Condition 2 is why this depends on `CameraUseDetector`: it costs nothing (a property
/// read, no capture, no permission) and it turns "your calendar says you're free" into
/// "you're actually done." It also catches the off-calendar Zoom, which is exactly where
/// a cover gets forgotten.
///
/// **One nudge per event, never a repeat.** A reminder that nags twice gets switched off,
/// and then it protects you never.
@MainActor
final class CameraCoverReminder: ObservableObject {

    private var cancellables = Set<AnyCancellable>()
    private var pendingCheck: Task<Void, Never>?
    /// Events already nudged for, so a re-entrant publisher can't double-fire.
    private var handledKeys: Set<String> = []

    private weak var config: CameraCoverConfig?
    private weak var calendarManager: CalendarManager?
    private weak var cameraDetector: CameraUseDetector?
    private weak var contextMonitor: MeetingContextMonitor?
    private weak var notificationManager: NotificationManager?
    private var diagnosticLog: DiagnosticLog?

    func attach(config: CameraCoverConfig,
                calendarManager: CalendarManager,
                cameraDetector: CameraUseDetector,
                contextMonitor: MeetingContextMonitor,
                notificationManager: NotificationManager,
                diagnosticLog: DiagnosticLog) {
        self.config = config
        self.calendarManager = calendarManager
        self.cameraDetector = cameraDetector
        self.contextMonitor = contextMonitor
        self.notificationManager = notificationManager
        self.diagnosticLog = diagnosticLog

        // Trigger 1: a scheduled meeting ended (set-diff, same pattern as the handoff
        // coordinator).
        var running = Set(calendarManager.meetingsCurrentlyRunning.map(\.id))
        calendarManager.$meetingsCurrentlyRunning
            .sink { [weak self] current in
                let currentIDs = Set(current.map(\.id))
                let ended = running.subtracting(currentIDs)
                running = currentIDs
                guard let ended = ended.first else { return }
                self?.scheduleCheck(key: "meeting_\(ended)", reason: "a meeting ended")
            }
            .store(in: &cancellables)

        // Trigger 2: the camera stopped streaming — catches the call that was never on
        // the calendar.
        cameraDetector.$isCameraInUse
            .removeDuplicates()
            .scan((false, false)) { previous, next in (previous.1, next) }
            .sink { [weak self] wasInUse, isInUse in
                guard wasInUse, !isInUse else { return }
                self?.scheduleCheck(key: "camera_\(Int(Date().timeIntervalSince1970 / 60))",
                                    reason: "the camera went quiet")
            }
            .store(in: &cancellables)
    }

    /// Wait out the delay, then re-test the conditions. They're checked at *fire* time,
    /// not schedule time, because everything relevant can change in two minutes.
    private func scheduleCheck(key: String, reason: String) {
        guard let config, config.isEnabled else { return }
        guard !handledKeys.contains(key) else { return }
        handledKeys.insert(key)

        pendingCheck?.cancel()
        let delay = max(0, config.delayMinutes)
        diagnosticLog?.debug(.notification, "Camera-cover check scheduled in \(delay)m — \(reason)")
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fireIfAppropriate(reason: reason)
        }
    }

    private func fireIfAppropriate(reason: String) {
        guard let config, config.isEnabled, let calendarManager else { return }

        if !calendarManager.meetingsCurrentlyRunning.isEmpty {
            diagnosticLog?.info(.notification, "Camera-cover reminder skipped — a meeting is running")
            return
        }
        if cameraDetector?.isCameraInUse == true {
            diagnosticLog?.info(.notification, "Camera-cover reminder skipped — the camera is still in use")
            return
        }
        // Focus / Do Not Disturb: skip entirely. macOS would hold the banner anyway, but
        // our sound is played directly by the app, so it would NOT be silenced — you'd
        // get a noise with no banner to explain it, during the one mode where you asked
        // not to be disturbed. A cover nudge is never urgent enough to earn that.
        if contextMonitor?.snapshot.isFocusActive == true {
            diagnosticLog?.info(.notification, "Camera-cover reminder skipped — Focus is on")
            return
        }
        if let next = calendarManager.upcomingMeetings.first(where: { $0.timeUntilStart > 0 && !$0.isCancelled }),
           next.timeUntilStart <= TimeInterval(config.skipIfNextMeetingWithinMinutes * 60) {
            diagnosticLog?.info(.notification, "Camera-cover reminder skipped — \"\(next.title)\" starts in \(Int(next.timeUntilStart / 60))m")
            return
        }

        diagnosticLog?.info(.notification, "Camera-cover reminder firing (\(reason))")
        notificationManager?.sendCameraCoverNotification()
    }

    /// Settings "Test" — bypasses the delay and the gates so you can hear the sound and
    /// see the wording without waiting for a meeting to end.
    ///
    /// It does NOT bypass Focus, because it can't: macOS holds the banner, and a test
    /// that plays a sound with no visible banner reads as a broken feature (it cost a
    /// round trip of debugging exactly once). So we say so in the log, and Settings
    /// shows the same warning inline.
    func testNow() {
        if contextMonitor?.snapshot.isFocusActive == true {
            diagnosticLog?.warn(.notification, "Camera-cover test sent while Focus is on — macOS will hold the banner")
        }
        notificationManager?.sendCameraCoverNotification(isTest: true)
    }

    /// True when a test would be swallowed by Focus — drives the inline Settings hint.
    var focusWouldSuppress: Bool { contextMonitor?.snapshot.isFocusActive == true }
}
