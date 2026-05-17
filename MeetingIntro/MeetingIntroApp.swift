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
                mixkitSounds: mixkitSounds
            )
        } label: {
            Label("MeetingIntro", systemImage: "clock.badge.checkmark")
        }
        .menuBarExtraStyle(.menu)

        // MARK: - Settings Window
        Settings {
            SettingsView(calendarManager: calendarManager, audioManager: audioManager, voiceReminder: voiceReminder, notificationManager: notificationManager, countdownConfig: countdownConfig, mixkitSounds: mixkitSounds)
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
        mixkitSounds: MixkitSoundManager
    ) {
        // Wire the config manager into CalendarManager
        calendarManager.countdownConfigs = countdownConfig
        notificationManager.soundManager = mixkitSounds
        overlayController.configure(calendarManager: calendarManager, audioManager: audioManager)
        calendarManager.startPolling()
        notificationManager.requestPermission()

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

        // Check upcoming meetings for voice + notification triggers per config
        calendarManager.$upcomingMeetings
            .sink { meetings in
                for meeting in meetings where meeting.timeUntilStart > 0 {
                    for trigger in countdownConfig.triggers {
                        let threshold = TimeInterval(trigger.minutes * 60)
                        guard meeting.timeUntilStart <= threshold else { continue }

                        // System notification per trigger
                        if trigger.sendNotification {
                            notificationManager.sendCountdownNotification(for: meeting, minutesBefore: trigger.minutes)
                        }

                        // Voice reminder per trigger
                        if trigger.playVoice {
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
                mixkitSounds: mixkitSounds
            )
        }
    }
}

