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

    /// Focus/Do Not Disturb holds a notification banner, so when this is on the reminder
    /// switches to the app's own corner panel — a window, which Focus doesn't govern —
    /// instead of being swallowed. Default on: someone who turns this feature on wants
    /// the nudge, and DND is usually about *other people's* interruptions.
    @Published var notifyDuringFocus: Bool {
        didSet { UserDefaults.standard.set(notifyDuringFocus, forKey: "cameraCoverNotifyDuringFocus") }
    }

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: "cameraCoverReminderEnabled") as? Bool ?? false
        self.notifyDuringFocus = d.object(forKey: "cameraCoverNotifyDuringFocus") as? Bool ?? true
        self.delayMinutes = d.object(forKey: "cameraCoverDelayMinutes") as? Int ?? 2
        self.skipIfNextMeetingWithinMinutes = d.object(forKey: "cameraCoverSkipWithinMinutes") as? Int ?? 10
    }
}

/// The rotating wordings for the nudge. Every one **asks** rather than tells, because
/// the app genuinely cannot see the cover — the phrasing carries that honesty, so don't
/// add a variant that asserts the camera is uncovered.
///
/// Rotation matters more here than for a meeting reminder: this is the same message over
/// and over, forever. Identical text becomes wallpaper faster than varied text does.
/// (Same reasoning as `VoiceReminderManager.phraseTemplates`.)
enum CameraCoverMessage {
    static let templates: [(title: String, subtitle: String)] = [
        ("Is your meeting over?", "If so, close your camera cover."),
        ("Close camera flap if open", "You're out of meetings."),
        ("Meeting's over", "Is your camera still uncovered?"),
        ("Camera check", "Is the cover back on?"),
        ("You're out of meetings", "Cover the camera?"),
        ("Done for now?", "Slide the camera cover shut.")
    ]

    /// Pick a wording, never the same one twice in a row.
    static func next(avoiding last: Int?) -> (index: Int, title: String, subtitle: String) {
        let choices = templates.indices.filter { $0 != last }
        let index = choices.randomElement() ?? 0
        return (index, templates[index].title, templates[index].subtitle)
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
    private weak var overlayController: OverlayWindowController?
    /// Last wording used, so rotation never repeats back to back.
    private var lastMessageIndex: Int?
    private weak var notificationManager: NotificationManager?
    private var diagnosticLog: DiagnosticLog?

    func attach(config: CameraCoverConfig,
                calendarManager: CalendarManager,
                cameraDetector: CameraUseDetector,
                contextMonitor: MeetingContextMonitor,
                overlayController: OverlayWindowController,
                notificationManager: NotificationManager,
                diagnosticLog: DiagnosticLog) {
        self.config = config
        self.calendarManager = calendarManager
        self.cameraDetector = cameraDetector
        self.contextMonitor = contextMonitor
        self.overlayController = overlayController
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
        if let next = calendarManager.upcomingMeetings.first(where: { $0.timeUntilStart > 0 && !$0.isCancelled }),
           next.timeUntilStart <= TimeInterval(config.skipIfNextMeetingWithinMinutes * 60) {
            diagnosticLog?.info(.notification, "Camera-cover reminder skipped — \"\(next.title)\" starts in \(Int(next.timeUntilStart / 60))m")
            return
        }

        diagnosticLog?.info(.notification, "Camera-cover reminder firing (\(reason))")
        present()
    }

    /// Choose the surface and show the nudge.
    ///
    /// Focus off → a normal notification. Focus on → the app's own corner panel, because
    /// macOS holds banners during Focus and the sanctioned way around that
    /// (`interruptionLevel = .timeSensitive`) needs a restricted entitlement and is
    /// downgraded **silently** when unauthorized — a promise we couldn't keep. A panel is
    /// a window; Focus doesn't govern it. With `notifyDuringFocus` off we stay quiet
    /// entirely, sound included.
    private func present(isTest: Bool = false) {
        let message = CameraCoverMessage.next(avoiding: lastMessageIndex)
        lastMessageIndex = message.index

        if contextMonitor?.snapshot.isFocusActive == true {
            guard config?.notifyDuringFocus == true else {
                diagnosticLog?.info(.notification, "Camera-cover reminder skipped — Focus is on and 'remind me anyway' is off")
                return
            }
            diagnosticLog?.info(.notification, "Camera-cover shown as a panel — Focus would hold a banner")
            overlayController?.showCameraCover(title: message.title, subtitle: message.subtitle)
            notificationManager?.playCameraCoverSound()
        } else {
            notificationManager?.sendCameraCoverNotification(title: message.title,
                                                             subtitle: message.subtitle,
                                                             isTest: isTest)
        }
    }

    /// Settings "Test" — bypasses the delay and the gates so you can see the wording and
    /// hear the sound without waiting for a meeting to end. It goes through the same
    /// surface selection, so testing under Focus shows you exactly what Focus will get.
    func testNow() { present(isTest: true) }
}
