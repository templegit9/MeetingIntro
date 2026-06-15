import AppKit
import SwiftUI
import Combine
import UserNotifications

/// Holds a weak reference to the recording coordinator so the OS-level
/// `applicationShouldTerminate` callback can block app quit until a recording is
/// finalized. The coordinator is injected by `AppLifecycleManager.observe` once the
/// `@StateObject`s exist.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var recordingCoordinator: MeetingRecordingCoordinator?
    weak var diagnosticLog: DiagnosticLog?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // CRITICAL: without a delegate, macOS silently drops notifications posted
        // while the app is foreground/active — and a menu-bar app the user clicks
        // into is "active" constantly, so reminders + cancellation notices never
        // appeared. Setting this delegate + opting in via willPresent is the fix.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Show notifications even when MeetingIntro is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            diagnosticLog?.info(.notification, "Foreground present: \(notification.request.content.title) — \(notification.request.content.subtitle)")
        }
        completionHandler([.banner, .list, .sound])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coord = recordingCoordinator, coord.isRecording else {
            return .terminateNow
        }
        // Tell macOS we need a moment; finalize the recording, then let the quit proceed.
        // Without this, the AVAssetWriter is force-killed mid-write and we lose the file.
        Task { @MainActor in
            await coord.stopManually()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Main entry point for the MeetingIntro menu bar app.
@main
struct MeetingIntroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var calendarManager = CalendarManager()
    @StateObject private var audioManager = AudioManager()
    @StateObject private var overlayController = OverlayWindowController()
    @StateObject private var voiceReminder = VoiceReminderManager()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var countdownConfig = CountdownConfigManager()
    @StateObject private var mixkitSounds = MixkitSoundManager()
    @StateObject private var contextMonitor = MeetingContextMonitor()
    @StateObject private var smartConfig = SmartConfigManager()
    @StateObject private var audioRouter: AudioRouter
    @StateObject private var handoffConfig: HandoffConfigManager
    @StateObject private var handoffCoordinator: MeetingHandoffCoordinator
    @StateObject private var recordingConfig: RecordingConfig
    @StateObject private var recordingController: RecordingController
    @StateObject private var recordingCoordinator: MeetingRecordingCoordinator
    @StateObject private var quickAddConfig: QuickAddConfig
    @StateObject private var quickAddService: QuickAddService
    @StateObject private var quickAddPanel: QuickAddPanelController
    @StateObject private var notesConfig: MeetingNotesConfig
    @StateObject private var notesPipeline: MeetingNotesPipeline
    @StateObject private var diagnosticLog = DiagnosticLog()
    @StateObject private var mirrorConfig = MirrorConfigManager()
    @StateObject private var mirrorEngine = CalendarMirrorEngine()
    @StateObject private var menuBarCountdown = MenuBarCountdownModel()
    @StateObject private var lifecycleManager = AppLifecycleManager()
    @StateObject private var updater = AppUpdater()

    init() {
        let router = AudioRouter()
        let config = HandoffConfigManager()
        let focus = FocusModeController()
        _audioRouter = StateObject(wrappedValue: router)
        _handoffConfig = StateObject(wrappedValue: config)
        _handoffCoordinator = StateObject(wrappedValue: MeetingHandoffCoordinator(router: router, focus: focus, config: config))

        let recConfig = RecordingConfig()
        let recController = RecordingController()
        _recordingConfig = StateObject(wrappedValue: recConfig)
        _recordingController = StateObject(wrappedValue: recController)
        _recordingCoordinator = StateObject(wrappedValue: MeetingRecordingCoordinator(config: recConfig, controller: recController))

        let qaConfig = QuickAddConfig()
        let qaService = QuickAddService(config: qaConfig)
        _quickAddConfig = StateObject(wrappedValue: qaConfig)
        _quickAddService = StateObject(wrappedValue: qaService)
        _quickAddPanel = StateObject(wrappedValue: QuickAddPanelController(service: qaService, config: qaConfig))

        let nConfig = MeetingNotesConfig()
        _notesConfig = StateObject(wrappedValue: nConfig)
        _notesPipeline = StateObject(wrappedValue: MeetingNotesPipeline(notesConfig: nConfig, quickAddConfig: qaConfig))
    }

    /// Single wiring point, called from the always-present menu-bar label so it runs in
    /// both menu and popover styles. Idempotent (guarded inside observe()).
    private func wireLifecycle() {
        lifecycleManager.observe(
            calendarManager: calendarManager,
            overlayController: overlayController,
            audioManager: audioManager,
            voiceReminder: voiceReminder,
            notificationManager: notificationManager,
            countdownConfig: countdownConfig,
            mixkitSounds: mixkitSounds,
            contextMonitor: contextMonitor,
            smartConfig: smartConfig,
            handoffCoordinator: handoffCoordinator,
            recordingCoordinator: recordingCoordinator,
            quickAddPanel: quickAddPanel,
            notesPipeline: notesPipeline,
            diagnosticLog: diagnosticLog,
            mirrorConfig: mirrorConfig,
            mirrorEngine: mirrorEngine,
            menuBarCountdown: menuBarCountdown
        )
    }

    /// The always-present status-bar label. observe() (the single wiring point) runs on
    /// its onAppear so it fires in both menu and popover styles. Red while recording.
    @ViewBuilder private var menuBarLabel: some View {
        Group {
            if recordingController.isRecording {
                Label("Recording", systemImage: "record.circle.fill")
            } else {
                Label("MeetingIntro", systemImage: "clock.badge.checkmark")
            }
        }
        .onAppear {
            wireLifecycle()
            updater.startAutoChecks()
        }
    }

    @AppStorage(MenuBarPresentation.storageKey) private var presentationRaw: String = MenuBarPresentation.popover.rawValue

    @ViewBuilder private var menuContent: some View {
        // The dropdown is a `.window`-style popover. Content branches on the user's
        // presentation setting: the compact menu-styled view (default) or the rich popover.
        if (MenuBarPresentation(rawValue: presentationRaw) ?? .menu) == .popover {
            PopoverRootView(
                calendarManager: calendarManager,
                recordingController: recordingController,
                recordingCoordinator: recordingCoordinator,
                quickAddPanel: quickAddPanel,
                updater: updater
            )
        } else {
            CompactMenuView(
                calendarManager: calendarManager,
                recordingController: recordingController,
                recordingCoordinator: recordingCoordinator,
                quickAddPanel: quickAddPanel,
                updater: updater
            )
        }
    }

    var body: some Scene {
        // MARK: - Menu Bar
        // `.window` style (not `.menu`): the native menu can't coexist with the rich
        // popover and SceneBuilder can't switch styles at runtime, so the dropdown is a
        // SwiftUI popover. Content branches (Phase 2) between CompactMenuView (default)
        // and the rich PopoverRootView. observe() runs from the always-present label.
        MenuBarExtra { menuContent } label: { menuBarLabel }
            .menuBarExtraStyle(.window)

        // MARK: - Settings Window
        Settings {
            SettingsView(
                calendarManager: calendarManager,
                audioManager: audioManager,
                voiceReminder: voiceReminder,
                notificationManager: notificationManager,
                countdownConfig: countdownConfig,
                mixkitSounds: mixkitSounds,
                contextMonitor: contextMonitor,
                smartConfig: smartConfig,
                audioRouter: audioRouter,
                handoffConfig: handoffConfig,
                handoffCoordinator: handoffCoordinator,
                recordingConfig: recordingConfig,
                recordingController: recordingController,
                recordingCoordinator: recordingCoordinator,
                overlayController: overlayController,
                quickAddConfig: quickAddConfig,
                quickAddPanel: quickAddPanel,
                notesConfig: notesConfig,
                diagnosticLog: diagnosticLog,
                mirrorConfig: mirrorConfig,
                mirrorEngine: mirrorEngine,
                updater: updater
            )
        }

        // MARK: - Meeting Notes viewer
        Window("Meeting Notes", id: "meetingNotes") {
            MeetingNotesWindow(
                pipeline: notesPipeline,
                notesConfig: notesConfig,
                recordingConfig: recordingConfig
            )
        }
        .defaultSize(width: 920, height: 620)
    }
}

// MARK: - App Delegate for lifecycle management

/// Observes CalendarManager state changes and controls the overlay window.
@MainActor
final class AppLifecycleManager: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    /// observe() wires subscriptions that must be set up exactly once. It's now driven
    /// from the always-present menu-bar label (so it runs in both menu and popover
    /// styles); this guard makes repeat onAppear calls no-ops instead of double-wiring.
    private var hasObserved = false

    // Cancellation-overlay hold bookkeeping (smart-context hold on the notice).
    /// When the smart-context hold first engaged for the current pending set (nil = not held).
    private var cancellationHoldStartedAt: Date?
    /// Last logged hold state, so we log "held"/"showing" only on transition, not every tick.
    private var lastLoggedCancellationHold: Bool?
    /// When the current continuous in-call episode began (nil = not in a call).
    private var inCallSince: Date?
    /// Whether we've already emitted the "stuck suppression" warn for the current episode.
    private var loggedStuckSuppressionWarn = false

    /// After this long, surface a held cancellation notice anyway — an acknowledgment
    /// surface must never hide indefinitely (overnight cancellations were stuck ~11.5h
    /// in the v2.7.0 regression). Date() comparison spans system sleep, so a notice
    /// held before lid-close is past the bound by lid-open.
    private static let cancellationHoldMaxInterval: TimeInterval = 30 * 60
    /// Emit a WARN once if in-call suppression persists past this — greppable signal
    /// that all-channel muting has been latched abnormally long.
    private static let stuckSuppressionWarnInterval: TimeInterval = 90 * 60

    /// A meeting-start notification fires only for a meeting that started within this
    /// window — so launch / wake (where `meetingsCurrentlyRunning` surfaces meetings
    /// already in progress) doesn't fire "starting now" for something 40 min old.
    private static let meetingStartNotifyWindow: TimeInterval = 120

    func observe(
        calendarManager: CalendarManager,
        overlayController: OverlayWindowController,
        audioManager: AudioManager,
        voiceReminder: VoiceReminderManager,
        notificationManager: NotificationManager,
        countdownConfig: CountdownConfigManager,
        mixkitSounds: MixkitSoundManager,
        contextMonitor: MeetingContextMonitor,
        smartConfig: SmartConfigManager,
        handoffCoordinator: MeetingHandoffCoordinator,
        recordingCoordinator: MeetingRecordingCoordinator,
        quickAddPanel: QuickAddPanelController,
        notesPipeline: MeetingNotesPipeline,
        diagnosticLog: DiagnosticLog,
        mirrorConfig: MirrorConfigManager,
        mirrorEngine: CalendarMirrorEngine,
        menuBarCountdown: MenuBarCountdownModel
    ) {
        guard !hasObserved else { return }
        hasObserved = true

        // Wire the config manager into CalendarManager
        calendarManager.countdownConfigs = countdownConfig
        menuBarCountdown.configure(calendarManager: calendarManager, countdownConfig: countdownConfig)
        calendarManager.diagnosticLog = diagnosticLog
        notificationManager.soundManager = mixkitSounds
        notificationManager.diagnosticLog = diagnosticLog
        overlayController.diagnosticLog = diagnosticLog
        recordingCoordinator.diagnosticLog = diagnosticLog
        notesPipeline.diagnosticLog = diagnosticLog
        overlayController.configure(calendarManager: calendarManager, audioManager: audioManager)
        notificationManager.requestPermission()
        handoffCoordinator.attach(to: calendarManager)
        recordingCoordinator.notificationManager = notificationManager
        recordingCoordinator.notesPipeline = notesPipeline
        recordingCoordinator.attach(to: calendarManager)
        quickAddPanel.calendarManager = calendarManager
        notesPipeline.notificationManager = notificationManager
        mirrorEngine.diagnosticLog = diagnosticLog
        mirrorEngine.attach(config: mirrorConfig, calendarManager: calendarManager)
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.recordingCoordinator = recordingCoordinator
            delegate.diagnosticLog = diagnosticLog
        }

        // Triage header — the first thing to read when something's wrong.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        diagnosticLog.info(.lifecycle, "MeetingIntro \(appVersion) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Single decision point for all three channels (overlay / notification / voice).
        // The closure reads the live snapshot each time it's called, so toggling Focus or
        // muting in another call takes effect on the next firing without any further wiring.
        let decide: @MainActor (CountdownTrigger) -> ReminderDecision = { trigger in
            ReminderEscalationPolicy.decide(
                trigger: trigger,
                context: contextMonitor.snapshot,
                config: smartConfig
            )
        }
        calendarManager.shouldFireOverlay = { decide($0).showOverlay }

        // RSVP gate (shared by overlay, notification/voice, and recording). Reads the
        // live settings each call. Personal events / organizer / unknown never match.
        calendarManager.responseGate = { smartConfig.suppresses($0) }
        recordingCoordinator.responseSuppressed = { smartConfig.suppresses($0) }

        // Auto-join ("Start at Time") — surface each transition as a notification so
        // the auto-open is never silent (armed / fired / missed-while-away).
        calendarManager.onAutoJoinArmed = { notificationManager.sendAutoJoinArmedNotification(for: $0) }
        calendarManager.onAutoJoinFired = { notificationManager.sendAutoJoinFiredNotification(for: $0) }
        calendarManager.onAutoJoinMissed = { notificationManager.sendAutoJoinMissedNotification(for: $0) }

        // Gentle pre-start overlay — MenuBarCountdownModel publishes the soonest armed
        // meeting once it's inside the lead window; show/hide the heads-up accordingly.
        menuBarCountdown.$imminentMeeting
            .removeDuplicates { $0?.id == $1?.id }
            .sink { meeting in
                if let meeting {
                    overlayController.showAutoJoinImminent(
                        meeting,
                        onCancel: { calendarManager.disarmAutoJoin(meeting.id) },
                        onJoinNow: { calendarManager.joinNowAndDisarm(meeting.id) }
                    )
                } else {
                    overlayController.dismissAutoJoinImminent()
                }
            }
            .store(in: &cancellables)

        // Start polling AFTER the hook is set, so the first poll uses the policy.
        calendarManager.startPolling()

        calendarManager.$shouldShowCountdown
            .removeDuplicates()
            .sink { shouldShow in
                if shouldShow, let meeting = calendarManager.countdownMeeting {
                    overlayController.show(for: meeting)
                } else if !shouldShow {
                    if overlayController.isShowing {
                        overlayController.dismiss()
                    }
                }
            }
            .store(in: &cancellables)

        // Cancellation fan-out — fire a "Meeting cancelled" notification (and the
        // optional overlay notice) the first time we see each cancelled event, and
        // never again. This runs BEFORE the reminder fan-out so a freshly-cancelled
        // meeting can't accidentally fire a reminder in the same poll cycle.
        // Note: markCancellationNotified is called even when the notify toggle is
        // off — "notified" really means "seen", which the dropdown badge and the
        // dedup both depend on.
        calendarManager.$upcomingMeetings
            .sink { [weak calendarManager] meetings in
                guard let calendarManager else { return }
                for meeting in meetings where meeting.isCancelled {
                    if !calendarManager.notifiedCancellationIDs.contains(meeting.id) {
                        diagnosticLog.info(.cancellation, "Detected cancellation, firing notice — \(meeting.title)")
                        notificationManager.sendCancellationNotification(for: meeting)
                        calendarManager.markCancellationNotified(meeting.id)
                    }
                }
            }
            .store(in: &cancellables)

        // Cancellation notice — a persistent acknowledgment surface, not a toast.
        // Driven by state (pendingCancellations = notified but not dismissed,
        // persisted across restarts), so a cancellation that landed overnight is
        // still on screen at lid-open and stays until the user clicks Dismiss.
        // Smart-context hold: never float it over an active call or a shared
        // screen — it reappears automatically when the hold clears.
        Publishers.CombineLatest(calendarManager.$pendingCancellations, contextMonitor.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak calendarManager] pending, context in
                guard let self, let calendarManager else { return }

                // Track continuous in-call episodes and warn if all-channel suppression
                // latches abnormally long (additive triage trail — naming the signal).
                self.trackInCallSuppression(context: context, diagnosticLog: diagnosticLog)

                guard UserDefaults.standard.bool(forKey: "cancellationShowOverlay") else {
                    self.cancellationHoldStartedAt = nil
                    self.lastLoggedCancellationHold = nil
                    overlayController.dismissCancellationNotice()
                    return
                }

                if pending.isEmpty {
                    self.cancellationHoldStartedAt = nil
                    self.lastLoggedCancellationHold = nil
                    overlayController.dismissCancellationNotice()
                    return
                }

                let smartHeld = (smartConfig.suppressWhenInCall && context.isInActiveCall)
                    || context.isScreenCaptured

                // Safety valve: an acknowledgment surface must never hide indefinitely.
                // Once the hold has persisted past the bound, surface it anyway.
                if smartHeld {
                    let startedAt = self.cancellationHoldStartedAt ?? Date()
                    self.cancellationHoldStartedAt = startedAt
                    let elapsed = Date().timeIntervalSince(startedAt)
                    if elapsed >= Self.cancellationHoldMaxInterval {
                        if self.lastLoggedCancellationHold != false {
                            diagnosticLog.warn(.overlay, "Cancellation overlay hold exceeded \(Int(Self.cancellationHoldMaxInterval / 60))m — surfacing anyway (\(pending.count) pending)")
                            self.lastLoggedCancellationHold = false
                        }
                        overlayController.showCancellationCenter(pending) { id in
                            calendarManager.dismissCancellation(id)
                        }
                        return
                    }
                    // Still within the hold window — keep hidden, log only on transition.
                    if self.lastLoggedCancellationHold != true {
                        diagnosticLog.info(.overlay, "Cancellation overlay held (\(context.isInActiveCall ? "in call" : "screen sharing")) — \(pending.count) pending")
                        self.lastLoggedCancellationHold = true
                    }
                    overlayController.dismissCancellationNotice()
                    return
                }

                // Not held — show, logging only on transition out of a hold.
                self.cancellationHoldStartedAt = nil
                if self.lastLoggedCancellationHold != false {
                    diagnosticLog.info(.overlay, "Showing cancellation overlay — \(pending.count) pending")
                    self.lastLoggedCancellationHold = false
                }
                overlayController.showCancellationCenter(pending) { id in
                    calendarManager.dismissCancellation(id)
                }
            }
            .store(in: &cancellables)

        // Fan out notifications + voice through the same policy. The freshness gate
        // (secondsSinceCrossed <= 60) suppresses backed-up reminders whose threshold
        // crossing happened during sleep — without it, waking the laptop dumps every
        // missed "15 min before" / "5 min before" reminder at once. Cancelled meetings
        // are excluded — they fire a single cancellation notification at detection
        // time (above) and skip the original-start-time reminders entirely.
        calendarManager.$upcomingMeetings
            .sink { meetings in
                let maxThreshold = TimeInterval((countdownConfig.triggers.map(\.minutes).max() ?? 0) * 60)
                for meeting in meetings where meeting.timeUntilStart > 0 && !meeting.isCancelled {
                    // Armed for auto-join → the menu-bar countdown is the only surface;
                    // suppress every original-start-time reminder for this event.
                    if calendarManager.armedAutoJoinIDs.contains(meeting.id) { continue }
                    // RSVP gate: skip invitations the user declined / didn't answer.
                    if smartConfig.suppresses(meeting) {
                        // Log only when a reminder would actually have fired (avoids
                        // spamming the same suppression every 30s poll all day).
                        if meeting.timeUntilStart <= maxThreshold {
                            diagnosticLog.info(.reminder, "Suppressed \(meeting.title) — RSVP \(meeting.myResponse.rawValue) with skip settings on")
                        }
                        continue
                    }
                    for trigger in countdownConfig.triggers {
                        let threshold = TimeInterval(trigger.minutes * 60)
                        guard meeting.timeUntilStart <= threshold else { continue }
                        let secondsSinceCrossed = threshold - meeting.timeUntilStart
                        // Normal poll: only the freshly-crossed threshold. Catch-up
                        // poll (post-sleep): also the single most-imminent threshold
                        // missed during sleep — collapsed to one so a wake doesn't
                        // dump every backed-up reminder for the meeting.
                        let catchUp = calendarManager.catchUpThresholdMinutes(for: meeting) == trigger.minutes
                        guard secondsSinceCrossed <= 60 || catchUp else { continue }

                        let decision = decide(trigger)
                        diagnosticLog.info(.reminder, "Reminder \(trigger.minutes)m fired for \(meeting.title) — notify=\(decision.sendNotification) voice=\(decision.playVoice) overlay=\(decision.showOverlay)")

                        if decision.sendNotification {
                            notificationManager.sendCountdownNotification(for: meeting, minutesBefore: trigger.minutes)
                        }
                        if decision.playVoice {
                            voiceReminder.speakReminderIfNeeded(for: meeting)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Meeting-start notification (T-0). `meetingsCurrentlyRunning` already excludes
        // cancelled meetings; the freshness window keeps launch/wake from announcing a
        // meeting already long in progress, and the per-ID dedup keeps it to once.
        // Armed meetings are skipped — their auto-join posts its own "Joining" notice.
        calendarManager.$meetingsCurrentlyRunning
            .sink { running in
                let now = Date()
                for meeting in running {
                    guard now.timeIntervalSince(meeting.startDate) <= Self.meetingStartNotifyWindow else { continue }
                    if calendarManager.armedAutoJoinIDs.contains(meeting.id) { continue }
                    if smartConfig.suppresses(meeting) { continue }
                    notificationManager.sendMeetingStartedNotification(for: meeting)
                }
            }
            .store(in: &cancellables)
    }

    /// Tracks how long the system has continuously asserted "in a call" and emits a single
    /// WARN naming the asserting signal once the episode passes the bound. The v2.7.0 stuck
    /// suppression produced an entire broken day with zero WARN/ERROR — this makes an
    /// abnormally long all-channel mute greppable.
    private func trackInCallSuppression(context: MeetingContextSnapshot, diagnosticLog: DiagnosticLog) {
        guard context.isInActiveCall else {
            inCallSince = nil
            loggedStuckSuppressionWarn = false
            return
        }
        let since = inCallSince ?? Date()
        inCallSince = since
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= Self.stuckSuppressionWarnInterval && !loggedStuckSuppressionWarn {
            let signal = context.isMicrophoneInUseElsewhere ? "mic in use" : "conference app"
            diagnosticLog.warn(.reminder, "In-call suppression has persisted \(Int(elapsed / 60))m (signal: \(signal)) — reminders muted; verify this is a real call")
            loggedStuckSuppressionWarn = true
        }
    }
}


