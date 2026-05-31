import SwiftUI
import Combine

/// Main entry point for the MeetingIntro menu bar app.
@main
struct MeetingIntroApp: App {

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
                recordingCoordinator: recordingCoordinator
            )
        } label: {
            Label("MeetingIntro", systemImage: "clock.badge.checkmark")
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
                recordingCoordinator: recordingCoordinator
            )
        }
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
        recordingCoordinator: MeetingRecordingCoordinator
    ) {
        // Wire the config manager into CalendarManager
        calendarManager.countdownConfigs = countdownConfig
        notificationManager.soundManager = mixkitSounds
        overlayController.configure(calendarManager: calendarManager, audioManager: audioManager)
        notificationManager.requestPermission()
        handoffCoordinator.attach(to: calendarManager)
        recordingCoordinator.attach(to: calendarManager)

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

        // Fan out notifications + voice through the same policy. The freshness gate
        // (secondsSinceCrossed <= 60) suppresses backed-up reminders whose threshold
        // crossing happened during sleep — without it, waking the laptop dumps every
        // missed "15 min before" / "5 min before" reminder at once.
        calendarManager.$upcomingMeetings
            .sink { meetings in
                for meeting in meetings where meeting.timeUntilStart > 0 {
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

    @StateObject private var lifecycleManager = AppLifecycleManager()

    var body: some View {
        Group {
            if let next = calendarManager.nextMeeting {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next Meeting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .font(.headline)
                    Text("\(next.formattedStartTime) · \(next.calendarName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                Label("No upcoming meetings", systemImage: "calendar")
                    .padding(.horizontal, 8)
            }

            Divider()

            if let error = calendarManager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 8)
                Divider()
            }

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
                recordingCoordinator: recordingCoordinator
            )
        }
    }
}

