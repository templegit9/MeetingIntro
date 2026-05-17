import Combine
import Foundation

/// Orchestrates calendar event polling using the active calendar provider.
/// Publishes upcoming meetings and triggers countdown when threshold is reached.
@MainActor
final class CalendarManager: ObservableObject {

    // MARK: - Published State

    /// All upcoming meetings from the active provider.
    @Published var upcomingMeetings: [MeetingEvent] = []

    /// The next meeting that hasn't been triggered yet.
    @Published var nextMeeting: MeetingEvent?

    /// Whether a countdown should be active right now.
    @Published var shouldShowCountdown: Bool = false

    /// The meeting currently being counted down to.
    @Published var countdownMeeting: MeetingEvent?

    /// Error message if the last fetch failed.
    @Published var errorMessage: String?

    /// Whether the provider is authorized.
    @Published var isAuthorized: Bool = false

    // MARK: - Configuration (from UserDefaults)

    /// The countdown config manager holds per-trigger notification preferences.
    /// CalendarManager reads enabled minutes from it.
    var countdownConfigs: CountdownConfigManager?

    /// Convenience: list of all enabled countdown minutes.
    var countdownMinutesList: [Int] {
        countdownConfigs?.enabledMinutes ?? [2]
    }

    /// How far ahead to look for meetings (in seconds). Default: 1 hour.
    var lookAheadInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "lookAheadInterval")
        return stored > 0 ? stored : 3600
    }

    /// Set of calendar IDs to monitor (empty = all).
    var selectedCalendarIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "selectedCalendarIDs") ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "selectedCalendarIDs")
            updateProviderCalendarFilter()
        }
    }

    // MARK: - Providers

    private let eventKitProvider = EventKitProvider()
    private let graphProvider = GraphCalendarProvider()

    /// The currently active provider type.
    var activeProviderType: CalendarProviderType {
        get {
            let raw = UserDefaults.standard.string(forKey: "activeProviderType") ?? CalendarProviderType.eventKit.rawValue
            return CalendarProviderType(rawValue: raw) ?? .eventKit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "activeProviderType")
            objectWillChange.send()
            Task { await refreshEvents() }
        }
    }

    /// Returns the currently active provider instance.
    var activeProvider: CalendarProvider {
        switch activeProviderType {
        case .eventKit: return eventKitProvider
        case .microsoftGraph: return graphProvider
        }
    }

    // MARK: - Private State

    private var pollTimer: Timer?
    /// Tracks which (meetingID, minutesBefore) combos have already been triggered.
    private var triggeredCombinations: Set<String> = []

    // MARK: - Lifecycle

    init() {
        updateProviderCalendarFilter()
    }

    /// Start polling for calendar events.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshEvents()
            }
        }
        // Also fetch immediately
        Task { await refreshEvents() }
    }

    /// Stop polling.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Event Fetching

    /// Refresh events from the active provider.
    func refreshEvents() async {
        do {
            // Check authorization
            if !activeProvider.isAuthorized {
                let granted = try await activeProvider.requestAccess()
                isAuthorized = granted
                if !granted {
                    errorMessage = "Calendar access not granted."
                    return
                }
            } else {
                isAuthorized = true
            }

            let events = try await activeProvider.fetchUpcomingEvents(within: lookAheadInterval)
            upcomingMeetings = events
            errorMessage = nil

            evaluateCountdownTrigger()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Countdown Logic

    /// Check if any meeting is within any of the countdown thresholds.
    private func evaluateCountdownTrigger() {
        // For each meeting, check each configured countdown time
        for event in upcomingMeetings where event.timeUntilStart > 0 {
            for minutes in countdownMinutesList {
                let thresholdSeconds = TimeInterval(minutes * 60)
                let comboKey = "\(event.id)_\(minutes)"

                if event.timeUntilStart <= thresholdSeconds &&
                   !triggeredCombinations.contains(comboKey) {
                    triggeredCombinations.insert(comboKey)

                    // Only show overlay if this trigger has it enabled
                    let triggerConfig = countdownConfigs?.trigger(for: minutes)
                    if triggerConfig?.showOverlay ?? true, !shouldShowCountdown {
                        nextMeeting = event
                        countdownMeeting = event
                        shouldShowCountdown = true
                    }
                    return // Only trigger one at a time
                }
            }
        }

        // Update nextMeeting to the soonest future meeting
        nextMeeting = upcomingMeetings.first { $0.timeUntilStart > 0 }

        // If the countdown meeting has started, auto-dismiss
        if let current = countdownMeeting, current.timeUntilStart <= 0 {
            shouldShowCountdown = false
            countdownMeeting = nil
        }
    }

    /// Called when the user manually dismisses the countdown overlay.
    func dismissCountdown() {
        shouldShowCountdown = false
        countdownMeeting = nil
    }

    /// Reset triggered state (e.g., at midnight or on provider switch).
    func resetTriggerState() {
        triggeredCombinations.removeAll()
    }

    // MARK: - Provider Helpers

    private func updateProviderCalendarFilter() {
        let ids = selectedCalendarIDs
        eventKitProvider.selectedCalendarIDs = ids
        graphProvider.selectedCalendarIDs = ids
    }

    /// Get the Graph provider for settings UI (sign in/out).
    var graphCalendarProvider: GraphCalendarProvider {
        graphProvider
    }
}
