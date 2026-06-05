import AppKit
import SwiftUI
import Combine

/// Holds a weak reference to the recording coordinator so the OS-level
/// `applicationShouldTerminate` callback can block app quit until a recording is
/// finalized. The coordinator is injected by `AppLifecycleManager.observe` once the
/// `@StateObject`s exist.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingCoordinator: MeetingRecordingCoordinator?

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

    var body: some Scene {
        // MARK: - Menu Bar
        MenuBarExtra {
            MenuBarView(
                calendarManager: calendarManager,
                audioManager: audioManager,
                overlayController: overlayController,
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
                quickAddPanel: quickAddPanel,
                notesPipeline: notesPipeline
            )
        } label: {
            // When recording, swap the menu bar glyph to a red record symbol so the
            // user has an at-a-glance signal from anywhere on screen — not just the
            // OS-level dot, which isn't MeetingIntro-specific.
            if recordingController.isRecording {
                Label("Recording", systemImage: "record.circle.fill")
            } else {
                Label("MeetingIntro", systemImage: "clock.badge.checkmark")
            }
        }
        .menuBarExtraStyle(.menu)

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
                notesConfig: notesConfig
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
        notesPipeline: MeetingNotesPipeline
    ) {
        // Wire the config manager into CalendarManager
        calendarManager.countdownConfigs = countdownConfig
        notificationManager.soundManager = mixkitSounds
        overlayController.configure(calendarManager: calendarManager, audioManager: audioManager)
        notificationManager.requestPermission()
        handoffCoordinator.attach(to: calendarManager)
        recordingCoordinator.notificationManager = notificationManager
        recordingCoordinator.notesPipeline = notesPipeline
        recordingCoordinator.attach(to: calendarManager)
        quickAddPanel.calendarManager = calendarManager
        notesPipeline.notificationManager = notificationManager
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.recordingCoordinator = recordingCoordinator
        }

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
            .sink { [weak calendarManager] pending, context in
                guard let calendarManager else { return }
                guard UserDefaults.standard.bool(forKey: "cancellationShowOverlay") else {
                    overlayController.dismissCancellationNotice()
                    return
                }
                let held = (smartConfig.suppressWhenInCall && context.isInActiveCall)
                    || context.isScreenCaptured
                if pending.isEmpty || held {
                    overlayController.dismissCancellationNotice()
                } else {
                    overlayController.showCancellationCenter(pending) { id in
                        calendarManager.dismissCancellation(id)
                    }
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
                for meeting in meetings where meeting.timeUntilStart > 0 && !meeting.isCancelled {
                    for trigger in countdownConfig.triggers {
                        let threshold = TimeInterval(trigger.minutes * 60)
                        guard meeting.timeUntilStart <= threshold else { continue }
                        let secondsSinceCrossed = threshold - meeting.timeUntilStart
                        guard secondsSinceCrossed <= 60 else { continue }

                        let decision = decide(trigger)

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
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var calendarManager: CalendarManager
    @ObservedObject var audioManager: AudioManager
    @ObservedObject var overlayController: OverlayWindowController
    @ObservedObject var voiceReminder: VoiceReminderManager
    @ObservedObject var notificationManager: NotificationManager
    @ObservedObject var countdownConfig: CountdownConfigManager
    @ObservedObject var mixkitSounds: MixkitSoundManager
    @ObservedObject var contextMonitor: MeetingContextMonitor
    @ObservedObject var smartConfig: SmartConfigManager
    @ObservedObject var audioRouter: AudioRouter
    @ObservedObject var handoffConfig: HandoffConfigManager
    @ObservedObject var handoffCoordinator: MeetingHandoffCoordinator
    @ObservedObject var recordingConfig: RecordingConfig
    @ObservedObject var recordingController: RecordingController
    @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    @ObservedObject var quickAddPanel: QuickAddPanelController
    @ObservedObject var notesPipeline: MeetingNotesPipeline

    @Environment(\.openWindow) private var openWindow

    @StateObject private var lifecycleManager = AppLifecycleManager()
    @AppStorage("cancellationShowInTodayView") private var showCancelledInTodayView: Bool = true

    /// Today's meetings as displayed — cancelled ones filtered out when the user
    /// has turned off "show cancelled meetings in Today's Meetings". Display-side
    /// only; the underlying data (and suppression logic) is untouched.
    private var displayedTodaysMeetings: [MeetingEvent] {
        showCancelledInTodayView
            ? calendarManager.todaysMeetings
            : calendarManager.todaysMeetings.filter { !$0.isCancelled }
    }

    /// One meeting row as a single concatenated `Text`. NSMenu (the `.menu` extra
    /// style) flattens container views — an HStack of Texts becomes one menu item
    /// PER Text, splitting time/title/icon onto separate lines. Text concatenation
    /// is the only way to get a styled single-row layout inside NSMenu.
    private func meetingRowText(for meeting: MeetingEvent) -> Text {
        let time = Text(meeting.formattedStartTime)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)

        var title = Text(meeting.title).font(.body)
        if meeting.isCancelled {
            title = title.strikethrough().foregroundColor(.secondary)
        }

        // Trailing status glyph. Priority: cancelled → recording → live now → has link.
        let status: Text
        if meeting.isCancelled {
            status = Text("  ") + Text(Image(systemName: "xmark.circle.fill"))
                .font(.caption).foregroundColor(.red)
        } else if recordingController.isRecording,
                  recordingController.currentMeetingTitle == meeting.title {
            status = Text("  ") + Text(Image(systemName: "record.circle.fill"))
                .font(.caption).foregroundColor(.red)
        } else if meeting.startDate <= Date() && Date() < meeting.endDate {
            status = Text("  ") + Text(Image(systemName: "circle.fill"))
                .font(.system(size: 7)).foregroundColor(.green)
        } else if meeting.url != nil {
            status = Text("  ") + Text(Image(systemName: "video.fill"))
                .font(.caption2).foregroundColor(.accentColor)
        } else {
            status = Text("")
        }

        return time + Text(" ") + title + status
    }

    var body: some View {
        Group {
            // Recording status — shown above everything else when active so the user
            // can stop without digging through Settings. Single concatenated Text:
            // NSMenu splits container views into one menu item per child.
            if recordingController.isRecording, let title = recordingController.currentMeetingTitle {
                Text(Image(systemName: "record.circle.fill")).foregroundColor(.red).font(.caption)
                    + Text("  Recording — ").font(.system(.caption, weight: .semibold)).foregroundColor(.red)
                    + Text(title).font(.caption).foregroundColor(.secondary)
                Button("Stop Recording") {
                    Task { await recordingCoordinator.stopManually() }
                }
                .keyboardShortcut("s")
                Divider()
            }

            // Cancelled-today badge — persists across app restarts via UserDefaults
            // so a cancellation that fired overnight is still visible the next time
            // the user opens the dropdown. Each row is a Button (NSMenu-native);
            // clicking it dismisses that cancellation.
            if !calendarManager.pendingCancellations.isEmpty {
                Text("Cancelled Today — click to dismiss")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(.orange)
                ForEach(calendarManager.pendingCancellations) { meeting in
                    Button {
                        calendarManager.dismissCancellation(meeting.id)
                    } label: {
                        Text(Image(systemName: "xmark.circle.fill")).foregroundColor(.red).font(.caption)
                            + Text(" \(meeting.formattedStartTime) ")
                                .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                            + Text(meeting.title).font(.body)
                    }
                }
                Divider()
            }

            // Today's meetings list. Includes cancelled ones (struck-through) so the
            // user can see them in context — but they don't trigger reminders.
            // Each row is one concatenated Text → one NSMenu item → one visual line.
            if displayedTodaysMeetings.isEmpty {
                Label("No meetings today", systemImage: "calendar")
            } else {
                Text("Today's Meetings")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(displayedTodaysMeetings.prefix(8)) { meeting in
                    meetingRowText(for: meeting)
                }
                if displayedTodaysMeetings.count > 8 {
                    Text("+ \(displayedTodaysMeetings.count - 8) more")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Divider()

            if let error = calendarManager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 8)
                Divider()
            }

            Button("New Event…") {
                quickAddPanel.show()
            }
            .keyboardShortcut("n")

            Button("Meeting Notes…") {
                openWindow(id: "meetingNotes")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("m")

            Button("Refresh") {
                Task { await calendarManager.refreshEvents() }
            }
            .keyboardShortcut("r")

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit MeetingIntro") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 280, alignment: .leading)
        .onAppear {
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
                notesPipeline: notesPipeline
            )
        }
    }
}

