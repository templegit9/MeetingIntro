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
    weak var taskManager: TaskManager?
    weak var taskReminderCoordinator: TaskReminderCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Headless File Organizer self-test: `MEETINGINTRO_SELFTEST=1 <app-binary>`.
        if ProcessInfo.processInfo.environment["MEETINGINTRO_SELFTEST"] == "1" {
            let result = MainActor.assumeIsolated { FileOrganizer().runSelfTest() }
            print(result.log)
            exit(result.pass ? 0 : 1)
        }
        #endif
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

    /// Handle the task-due action buttons (Mark done / Snooze) — Issue #19.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        Task { @MainActor in
            if let taskID {
                switch action {
                case NotificationManager.taskDoneAction:
                    self.taskManager?.complete(taskID)
                case NotificationManager.taskSnoozeAction:
                    self.taskReminderCoordinator?.snooze(taskID: taskID, minutes: 10)
                default: break
                }
            }
            completionHandler()
        }
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
    @Environment(\.openWindow) private var openWindow

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
    @StateObject private var taskConfig: TaskConfig
    @StateObject private var taskManager: TaskManager
    @StateObject private var taskReminderCoordinator = TaskReminderCoordinator()
    @StateObject private var cameraDetector = CameraUseDetector()
    @StateObject private var cameraCoverConfig = CameraCoverConfig()
    @StateObject private var cameraCoverReminder = CameraCoverReminder()
    @StateObject private var tickerConfig = TickerConfig()
    @StateObject private var tickerCoordinator = TickerCoordinator()
    @StateObject private var assistantConfig = AssistantConfig()
    @StateObject private var fileOrganizer = FileOrganizer()
    @StateObject private var fileOrganizerCoordinator = FileOrganizerCoordinator()
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

        let tConfig = TaskConfig()
        _taskConfig = StateObject(wrappedValue: tConfig)
        _taskManager = StateObject(wrappedValue: TaskManager(config: tConfig))

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
            quickAddService: quickAddService,
            taskManager: taskManager,
            taskReminderCoordinator: taskReminderCoordinator,
            assistantConfig: assistantConfig,
            fileOrganizer: fileOrganizer,
            fileOrganizerCoordinator: fileOrganizerCoordinator,
            tickerConfig: tickerConfig,
            tickerCoordinator: tickerCoordinator,
            recordingController: recordingController,
            cameraDetector: cameraDetector,
            cameraCoverConfig: cameraCoverConfig,
            cameraCoverReminder: cameraCoverReminder,
            notesPipeline: notesPipeline,
            diagnosticLog: diagnosticLog,
            mirrorConfig: mirrorConfig,
            mirrorEngine: mirrorEngine,
            menuBarCountdown: menuBarCountdown
        )
    }

    /// The always-present status-bar label. observe() (the single wiring point) runs on
    /// its onAppear so it fires in both menu and popover styles. Red while recording.
    private var isUpdateAvailable: Bool {
        if case .available = updater.state { return true }
        return false
    }

    @ViewBuilder private var menuBarLabel: some View {
        // The menu-bar icon is a steady clock — it does NOT change for recording or
        // reminders-paused (those surface in the dropdown + notifications). The ONE
        // allowed change is a green checkmark badge when an app update is ready, so
        // the icon stays visually stable and easy to find (user request, 2026-07-27).
        Group {
            if isUpdateAvailable {
                // Green checkmark badge = an app update is ready to install.
                Label("Update available", systemImage: "clock.badge.checkmark")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.primary, .green)
            } else {
                Label("MeetingIntro", systemImage: "clock")
            }
        }
        .onAppear {
            wireLifecycle()
            updater.startAutoChecks()
        }
        // An automated organize run that needs review → open the Assistant window (which
        // renders the pending preview). Auto-apply runs don't publish a review, so no open.
        .onReceive(fileOrganizerCoordinator.$pendingReview.compactMap { $0 }) { _ in
            openWindow(id: "assistant")
            NSApp.activate(ignoringOtherApps: true)
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
                updater: updater,
                diagnosticLog: diagnosticLog,
                smartConfig: smartConfig,
                contextMonitor: contextMonitor,
                quickAddService: quickAddService,
                quickAddConfig: quickAddConfig,
                taskManager: taskManager
            )
        } else {
            CompactMenuView(
                calendarManager: calendarManager,
                recordingController: recordingController,
                recordingCoordinator: recordingCoordinator,
                updater: updater,
                smartConfig: smartConfig,
                contextMonitor: contextMonitor,
                quickAddService: quickAddService,
                quickAddConfig: quickAddConfig,
                taskManager: taskManager
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
                taskConfig: taskConfig,
                taskManager: taskManager,
                assistantConfig: assistantConfig,
                tickerConfig: tickerConfig,
                tickerCoordinator: tickerCoordinator,
                cameraCoverConfig: cameraCoverConfig,
                cameraCoverReminder: cameraCoverReminder,
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

        // File Organizer plugin (Issue #17) — opt-in AI file organizer.
        Window("File Organizer", id: "assistant") {
            AssistantWindow(config: assistantConfig, organizer: fileOrganizer, coordinator: fileOrganizerCoordinator)
        }
        .defaultSize(width: 640, height: 560)

        // Dictionary plugin — opt-in word lookup (meaning, synonyms, pronunciation).
        Window("Dictionary", id: "dictionary") {
            DictionaryWindow()
        }
        .defaultSize(width: 480, height: 560)
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
    /// Set once the current in-call episode passes the user's auto-release cap: the
    /// `decide` closure reads it to override the `.inCall` mute so a stuck/held mic stops
    /// silencing reminders. Reset when the call ends. (0-minute cap = never set.)
    private var inCallSuppressionCapExceeded = false

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
        quickAddService: QuickAddService,
        taskManager: TaskManager,
        taskReminderCoordinator: TaskReminderCoordinator,
        assistantConfig: AssistantConfig,
        fileOrganizer: FileOrganizer,
        fileOrganizerCoordinator: FileOrganizerCoordinator,
        tickerConfig: TickerConfig,
        tickerCoordinator: TickerCoordinator,
        recordingController: RecordingController,
        cameraDetector: CameraUseDetector,
        cameraCoverConfig: CameraCoverConfig,
        cameraCoverReminder: CameraCoverReminder,
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
        calendarManager.eventKitProvider.diagnosticLog = diagnosticLog
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
        // Wire the Quick Add conflict check (Issue #10) to the live calendar — this used
        // to ride on the retired QuickAddPanelController's calendarManager setter.
        quickAddService.conflictProvider = { [weak calendarManager] start, end in
            calendarManager?.conflicts(start: start, end: end).map(\.title) ?? []
        }
        // Tasks (Issue #19): the overlay's "Mark done" needs the manager; the coordinator
        // fires task deadline reminders on its own 30s timer.
        overlayController.taskManager = taskManager
        overlayController.taskReminderCoordinator = taskReminderCoordinator
        // Executive Assistant (Issue #17): wire the organizer to its config + log.
        fileOrganizer.attach(config: assistantConfig)
        fileOrganizer.diagnosticLog = diagnosticLog
        fileOrganizerCoordinator.attach(config: assistantConfig, organizer: fileOrganizer,
                                        notificationManager: notificationManager, diagnosticLog: diagnosticLog)
        // Camera-cover reminder (opt-in): nudges you to close a physical cover once
        // you're out of meetings. Uses CameraUseDetector purely as a gate — a property
        // read, never a capture, so no camera permission and no green LED.
        cameraCoverReminder.attach(config: cameraCoverConfig,
                                   calendarManager: calendarManager,
                                   cameraDetector: cameraDetector,
                                   notificationManager: notificationManager,
                                   diagnosticLog: diagnosticLog)

        // Ticker (opt-in plugin): read-only over existing published state — it can't
        // affect reminders, and it no-ops entirely while `tickerConfig.isEnabled` is off.
        tickerCoordinator.attach(config: tickerConfig,
                                 calendarManager: calendarManager,
                                 taskManager: taskManager,
                                 contextMonitor: contextMonitor,
                                 recordingController: recordingController,
                                 diagnosticLog: diagnosticLog)
        taskReminderCoordinator.attach(taskManager: taskManager,
                                       notificationManager: notificationManager,
                                       voiceReminder: voiceReminder,
                                       overlayController: overlayController,
                                       diagnosticLog: diagnosticLog)
        notesPipeline.notificationManager = notificationManager
        mirrorEngine.diagnosticLog = diagnosticLog
        mirrorEngine.attach(config: mirrorConfig, calendarManager: calendarManager)
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.recordingCoordinator = recordingCoordinator
            delegate.diagnosticLog = diagnosticLog
            delegate.taskManager = taskManager
            delegate.taskReminderCoordinator = taskReminderCoordinator
        }

        // Triage header — the first thing to read when something's wrong.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        diagnosticLog.info(.lifecycle, "MeetingIntro \(appVersion) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Single decision point for all three channels (overlay / notification / voice).
        // The closure reads the live snapshot each time it's called, so toggling Focus or
        // muting in another call takes effect on the next firing without any further wiring.
        let decide: @MainActor (CountdownTrigger, MeetingEvent) -> ReminderDecision = { [weak self] trigger, meeting in
            var decision = ReminderEscalationPolicy.decide(
                trigger: trigger,
                context: contextMonitor.snapshot,
                config: smartConfig
            )
            // Auto-release: if a stuck/held mic muted reminders past the configured cap,
            // resume them. Only the in-call mute is overridden — Focus / screen-sharing
            // suppression is left intact (guarded on `.inCall`).
            if decision.suppressedBy == .inCall, self?.inCallSuppressionCapExceeded == true {
                decision = .fromTrigger(trigger)
            }
            // Per-event notification rules (downgrade-only): a matching rule ANDs its
            // allowed channels onto the decision — it can silence but never add channels.
            if let mask = smartConfig.channelMask(for: meeting) {
                decision.showOverlay      = decision.showOverlay && mask.overlay
                decision.sendNotification = decision.sendNotification && mask.notify
                decision.playVoice        = decision.playVoice && mask.voice
            }
            return decision
        }
        calendarManager.shouldFireOverlay = { trigger, meeting in decide(trigger, meeting).showOverlay }

        // RSVP gate (shared by overlay, notification/voice, and recording). Reads the
        // live settings each call. Personal events / organizer / unknown never match.
        calendarManager.responseGate = { smartConfig.suppresses($0) }
        recordingCoordinator.responseSuppressed = { smartConfig.suppresses($0) }

        // Auto-join ("Start at Time") — surface each transition as a notification so
        // the auto-open is never silent (armed / fired / missed-while-away).
        calendarManager.onAutoJoinArmed = { notificationManager.sendAutoJoinArmedNotification(for: $0) }
        calendarManager.onAutoJoinFired = { notificationManager.sendAutoJoinFiredNotification(for: $0) }
        calendarManager.onAutoJoinClash = { [weak notificationManager] opened, skipped in
            notificationManager?.sendAutoJoinClashNotification(opened: opened, skipped: skipped)
        }
        calendarManager.onAutoJoinMissed = { notificationManager.sendAutoJoinMissedNotification(for: $0) }
        calendarManager.onMeetingTimeChanged = { notificationManager.sendTimeChangeNotification(for: $0, from: $1) }

        // Gentle pre-start overlay — MenuBarCountdownModel publishes the soonest armed
        // meeting once it's inside the lead window; show/hide the heads-up accordingly.
        menuBarCountdown.$imminentMeeting
            .removeDuplicates { $0?.id == $1?.id }
            .sink { meeting in
                if let meeting {
                    // Audible heads-up so a heads-down user gets a beat to stop typing
                    // before they're pulled into the call (Issue #8).
                    if countdownConfig.autoJoinAudibleCountdownEnabled {
                        MenuBarCountdownModel.playHeadsUpChime()
                    }
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
                    // Pass the whole group — several meetings can start together, and
                    // the user's ConcurrentOverlayStyle decides how they're presented.
                    let group = calendarManager.countdownMeetings.isEmpty
                        ? [meeting] : calendarManager.countdownMeetings
                    overlayController.show(for: group)
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
                self.trackInCallSuppression(context: context, config: smartConfig, diagnosticLog: diagnosticLog)

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
                // Collected first, dispatched below — so meetings that start together can
                // be merged into one notification / one spoken line.
                var notifyQueue: [(Int, MeetingEvent)] = []
                var voiceQueue: [(Int, MeetingEvent)] = []
                for meeting in meetings where meeting.timeUntilStart > 0 && !meeting.isCancelled {
                    // Armed for auto-join → the menu-bar countdown is the only surface;
                    // suppress every original-start-time reminder for this event.
                    if calendarManager.armedAutoJoinIDs.contains(meeting.id) { continue }
                    // User dismissed this event's reminders (Issue #15) — no threshold fires.
                    if calendarManager.dismissedReminderIDs.contains(meeting.id) { continue }
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

                        let decision = decide(trigger, meeting)
                        let reasonSuffix = decision.suppressedBy.map { " — suppressed: \($0.logDescription)" } ?? ""
                        let ruleSuffix = smartConfig.matchingRuleName(for: meeting).map { " — rule: \($0)" } ?? ""
                        diagnosticLog.info(.reminder, "Reminder \(trigger.minutes)m fired for \(meeting.title) — notify=\(decision.sendNotification) voice=\(decision.playVoice) overlay=\(decision.showOverlay)\(reasonSuffix)\(ruleSuffix)")

                        if decision.sendNotification { notifyQueue.append((trigger.minutes, meeting)) }
                        if decision.playVoice { voiceQueue.append((trigger.minutes, meeting)) }
                    }
                }

                // Dispatch what we collected. Meetings sharing a threshold AND a start
                // minute are one clash: without this, three 10:00 meetings meant three
                // banners landing on top of each other and the synthesizer reading three
                // reminders over itself. Grouping key is the START time (not "same poll"
                // as the overlay uses) so the banner can honestly say "3 meetings at
                // 10:00" — 9:58 and 10:00 stay separate messages.
                let clashKey: (Int, MeetingEvent) -> String = { minutes, meeting in
                    "\(minutes)_\(Int(meeting.startDate.timeIntervalSince1970 / 60))"
                }

                for (_, group) in Dictionary(grouping: notifyQueue, by: { clashKey($0.0, $0.1) }) {
                    let minutes = group[0].0
                    let meetings = CalendarManager.rankedForOverlay(group.map(\.1))
                    switch countdownConfig.concurrentNotificationStyle {
                    case .grouped:
                        notificationManager.sendGroupedCountdownNotification(for: meetings, minutesBefore: minutes)
                    case .threaded:
                        let thread = meetings.count > 1
                            ? "clash_\(Int(meetings[0].startDate.timeIntervalSince1970))" : nil
                        for meeting in meetings {
                            notificationManager.sendCountdownNotification(for: meeting, minutesBefore: minutes, threadID: thread)
                        }
                    case .separate:
                        for meeting in meetings {
                            notificationManager.sendCountdownNotification(for: meeting, minutesBefore: minutes)
                        }
                    }
                }

                for (_, group) in Dictionary(grouping: voiceQueue, by: { clashKey($0.0, $0.1) }) {
                    let minutes = group[0].0
                    let meetings = CalendarManager.rankedForOverlay(group.map(\.1))
                    voiceReminder.speakGroupReminderIfNeeded(for: meetings, minutesBefore: minutes)
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

    /// Tracks how long the system has continuously asserted "in a call." Two safety valves,
    /// both keyed off the same episode clock:
    ///   • **Auto-release cap** (`maxInCallSuppressionMinutes` > 0): once the episode passes
    ///     the cap, set `inCallSuppressionCapExceeded` so the `decide` closure resumes
    ///     reminders (a stuck/held mic can't mute forever — the v2.7.0-family failure),
    ///     and WARN once naming the signal.
    ///   • **Legacy WARN-only** (cap == 0, user opted out of auto-release): still emit a
    ///     single WARN at the 90-min bound so an abnormally long mute stays greppable.
    private func trackInCallSuppression(context: MeetingContextSnapshot, config: SmartConfigManager, diagnosticLog: DiagnosticLog) {
        guard context.isInActiveCall else {
            inCallSince = nil
            loggedStuckSuppressionWarn = false
            inCallSuppressionCapExceeded = false
            return
        }
        let since = inCallSince ?? Date()
        inCallSince = since
        let elapsed = Date().timeIntervalSince(since)
        let signal = context.isMicrophoneInUseElsewhere ? "mic in use" : "conference app"
        let capMin = config.maxInCallSuppressionMinutes

        if capMin > 0 {
            if elapsed >= TimeInterval(capMin * 60) && !inCallSuppressionCapExceeded {
                inCallSuppressionCapExceeded = true
                diagnosticLog.warn(.reminder, "In-call suppression exceeded \(capMin)m cap — auto-resuming reminders (signal: \(signal)). If you're not on a call, an app may be holding the mic.")
            }
        } else if elapsed >= Self.stuckSuppressionWarnInterval && !loggedStuckSuppressionWarn {
            diagnosticLog.warn(.reminder, "In-call suppression has persisted \(Int(elapsed / 60))m (signal: \(signal)) — reminders muted; verify this is a real call")
            loggedStuckSuppressionWarn = true
        }
    }
}


