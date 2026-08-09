import AppKit
import Combine
import SwiftUI

/// Drives the ticker: rebuilds the feed from live app state, applies the auto-hide rules,
/// and tells `TickerWindowController` to show/update/hide.
///
/// Attached in `AppLifecycleManager.observe` like the other coordinators. It reads the
/// existing published state (`CalendarManager`, `TaskManager`, `MeetingContextMonitor`,
/// `RecordingController`) and writes nothing back — the plugin can't affect reminders.
@MainActor
final class TickerCoordinator: ObservableObject {

    /// The feed currently on screen (also drives the Settings preview).
    @Published private(set) var items: [TickerItem] = []
    /// Why the strip is hidden right now, for the Settings status line. nil = showing (or
    /// the plugin is off).
    @Published private(set) var hiddenReason: String?

    private let window = TickerWindowController()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    private weak var config: TickerConfig?
    private weak var calendarManager: CalendarManager?
    private weak var taskManager: TaskManager?
    private weak var contextMonitor: MeetingContextMonitor?
    private weak var recordingController: RecordingController?
    private var diagnosticLog: DiagnosticLog?

    /// Countdown text ("in 12m") goes stale, so refresh on a slow tick as well as on
    /// state changes. 15s keeps the minutes honest without being a busy loop — the crawl
    /// itself is animated by Core Animation, not by this timer.
    private static let refreshInterval: TimeInterval = 15
    /// How long the Settings preview crawl stays up.
    private static let previewDuration: TimeInterval = 12
    /// While set (and in the future), refreshes leave the preview alone.
    private var previewUntil: Date?

    func attach(config: TickerConfig,
                calendarManager: CalendarManager,
                taskManager: TaskManager,
                contextMonitor: MeetingContextMonitor,
                recordingController: RecordingController,
                diagnosticLog: DiagnosticLog) {
        self.config = config
        self.calendarManager = calendarManager
        self.taskManager = taskManager
        self.contextMonitor = contextMonitor
        self.recordingController = recordingController
        self.diagnosticLog = diagnosticLog
        window.diagnosticLog = diagnosticLog

        // Anything that can change the feed or the hide decision.
        config.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
        calendarManager.$todaysMeetings
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        calendarManager.$pendingCancellations
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        taskManager.$tasks
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        contextMonitor.$snapshot
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        recordingController.$isRecording
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Screen changes (display plugged/unplugged, resolution change) → re-centre.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, let config = self.config else { return }
                self.window.reposition(width: config.width)
            }
            .store(in: &cancellables)

        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refresh()
    }

    /// Rebuild and apply. Cheap and idempotent — safe to call from every publisher.
    func refresh() {
        guard let config else { return }

        // A preview in flight owns the strip until it expires (but the plugin being
        // switched off still wins — see below).
        if let previewUntil, previewUntil > Date(), config.isEnabled {
            window.show(items: items, speed: config.scrollSpeed, width: config.width)
            return
        }
        previewUntil = nil

        guard config.isEnabled else {
            items = []
            hiddenReason = nil
            window.hide()
            return
        }

        if let reason = suppressionReason() {
            if hiddenReason != reason {
                diagnosticLog?.info(.ticker, "Ticker hidden — \(reason)")
            }
            hiddenReason = reason
            items = []
            window.hide()
            return
        }

        let feed = TickerFeed.build(
            meetings: calendarManager?.todaysMeetings ?? [],
            cancellations: calendarManager?.pendingCancellations ?? [],
            armed: calendarManager?.armedAutoJoinMeetings ?? [],
            tasks: taskManager?.tasks ?? [],
            isRecording: recordingController?.isRecording ?? false,
            recordingTitle: recordingController?.currentMeetingTitle,
            config: config
        )

        items = feed
        if feed.isEmpty {
            // Nothing to say → say nothing. The strip's presence is itself a signal.
            hiddenReason = "nothing to show"
            window.hide()
        } else {
            hiddenReason = nil
            window.show(items: feed, speed: config.scrollSpeed, width: config.width)
        }
    }

    /// Show a sample crawl for a few seconds, ignoring the sources and the auto-hide
    /// rules. Settings needs this: the real feed is often empty (no meetings left today,
    /// no tasks due), so without a preview there's no way to see where the strip lands or
    /// how fast it reads before committing to it.
    func showPreview() {
        guard let config else { return }
        let sample = [
            TickerItem(id: "preview_1", symbol: "calendar", text: "Quarterly Planning — in 12m (10:30 AM)", tint: .accent),
            TickerItem(id: "preview_2", symbol: "exclamationmark.circle.fill", text: "Overdue — Send the Q3 draft (Today 5:00 PM)", tint: .warning),
            TickerItem(id: "preview_3", symbol: "xmark.circle.fill", text: "Cancelled — Design review", tint: .alert),
            TickerItem(id: "preview_4", symbol: "checkmark.circle", text: "Task — Review PR · Tomorrow 9:00 AM", tint: .neutral)
        ]
        previewUntil = Date().addingTimeInterval(Self.previewDuration)
        items = sample
        hiddenReason = nil
        window.show(items: sample, speed: config.scrollSpeed, width: config.width)
        diagnosticLog?.info(.ticker, "Ticker preview shown")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDuration + 0.1) { [weak self] in
            self?.refresh()
        }
    }

    /// The user's auto-hide rules, in priority order. Returns nil when nothing suppresses.
    private func suppressionReason() -> String? {
        guard let config, let snapshot = contextMonitor?.snapshot else { return nil }
        if config.hideWhileScreenSharing, snapshot.isScreenCaptured { return "screen sharing" }
        if config.hideWhileInCall, snapshot.isInActiveCall { return "you're on a call" }
        if config.hideWhileFocus, snapshot.isFocusActive { return "Focus is on" }
        if config.hasNoSources { return "no sources selected" }
        return nil
    }
}
