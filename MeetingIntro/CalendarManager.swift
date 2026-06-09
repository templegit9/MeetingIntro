import Combine
import EventKit
import Foundation

/// Orchestrates calendar event polling using the active calendar provider.
/// Publishes upcoming meetings and triggers countdown when threshold is reached.
@MainActor
final class CalendarManager: ObservableObject {

    // MARK: - Published State

    /// All upcoming meetings from the active provider.
    @Published var upcomingMeetings: [MeetingEvent] = []

    /// Meetings whose start time has passed but end time has not. Updated on each poll.
    /// Used by `MeetingHandoffCoordinator` to drive enter/exit side effects.
    @Published var meetingsCurrentlyRunning: [MeetingEvent] = []

    /// All of today's meetings (sorted by start time). Includes cancelled ones so the
    /// menu bar dropdown can show them struck-through. Computed each refresh.
    @Published var todaysMeetings: [MeetingEvent] = []

    /// Cancelled meetings that have been notified to the user but not yet dismissed
    /// from the dropdown badge. Persisted across launches via `dismissedCancellationIDs`
    /// in UserDefaults — exactly the "someone cancelled overnight" case in Jon's doc.
    @Published var pendingCancellations: [MeetingEvent] = []

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

    /// Diagnostic log — injected in AppLifecycleManager.observe.
    var diagnosticLog: DiagnosticLog?

    /// Called at the end of each successful refresh — the calendar-mirror engine
    /// hooks here so reconciliation rides the existing 30s poll.
    var onPollComplete: (() -> Void)?

    /// Hook consulted before showing the overlay for a trigger. Returning `false`
    /// suppresses the overlay even when the trigger has `showOverlay = true` — used by
    /// `ReminderEscalationPolicy` to gate firings on live context (in-call, Focus, etc).
    /// Default behavior (when the hook is nil) is to respect the trigger flag directly.
    var shouldFireOverlay: ((CountdownTrigger) -> Bool)?

    /// Convenience: list of all enabled countdown minutes.
    var countdownMinutesList: [Int] {
        countdownConfigs?.enabledMinutes ?? [2]
    }

    /// How far ahead to look for meetings (in seconds).
    ///
    /// Default is dynamic: always through end of today + a 2-hour buffer, so the menu
    /// bar's "Today's Meetings" list reliably shows every event scheduled for the
    /// current day (and a peek at tomorrow's earliest for the next-meeting case).
    /// The previous fixed-1-hour default meant any meeting later than ~now+1h never
    /// appeared in `upcomingMeetings` and the today view falsely rendered as empty.
    /// User-set value via UserDefaults still wins.
    var lookAheadInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "lookAheadInterval")
        if stored > 0 { return stored }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date())
            ?? Date().addingTimeInterval(86400)
        return max(3600, endOfDay.timeIntervalSinceNow + 7200)
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

    /// Internal (not private) so the calendar-mirror engine reconciles against the
    /// SAME EKEventStore this manager reads from — an EKEvent fetched from one store
    /// can't be saved via another.
    let eventKitProvider = EventKitProvider()
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
    private var eventStoreObserver: NSObjectProtocol?
    /// Tracks which (meetingID, minutesBefore) combos have already been triggered.
    private var triggeredCombinations: Set<String> = []

    /// Cancellation IDs we've already fired a system notification for. Persisted to
    /// UserDefaults so a relaunch doesn't re-notify for the same cancellation.
    private(set) var notifiedCancellationIDs: Set<String> = []
    /// Cancellation IDs the user has dismissed from the menu bar badge.
    private(set) var dismissedCancellationIDs: Set<String> = []
    private static let k_notifiedCancellations = "notifiedCancellationIDs"
    private static let k_dismissedCancellations = "dismissedCancellationIDs"

    // MARK: - Lifecycle

    init() {
        updateProviderCalendarFilter()
        let d = UserDefaults.standard
        self.notifiedCancellationIDs = Set(d.stringArray(forKey: Self.k_notifiedCancellations) ?? [])
        self.dismissedCancellationIDs = Set(d.stringArray(forKey: Self.k_dismissedCancellations) ?? [])
    }

    /// Start polling for calendar events.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshEvents()
            }
        }

        // EventKit posts EKEventStoreChanged when the calendar database changes — which
        // includes permission grant/revoke. Subscribing here means granting calendar
        // access from System Settings triggers a refresh immediately, no app restart.
        if eventStoreObserver == nil {
            eventStoreObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventKitProvider.eventStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshEvents() }
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
        // Clear any prior error before re-evaluating. If the refresh fails for a real
        // reason we set it again below; if it succeeds, we don't carry a stale "access
        // was denied" message after the user has actually granted access.
        errorMessage = nil

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
            diagnosticLog?.debug(.calendar, "Poll: \(events.count) events in window (\(activeProviderType.rawValue))")
            let now = Date()
            meetingsCurrentlyRunning = events.filter { $0.startDate <= now && now < $0.endDate && !$0.isCancelled }
            todaysMeetings = events
                .filter { Calendar.current.isDateInToday($0.startDate) }
                .sorted { $0.startDate < $1.startDate }
            pendingCancellations = events.filter {
                $0.isCancelled
                    && notifiedCancellationIDs.contains($0.id)
                    && !dismissedCancellationIDs.contains($0.id)
            }
            pruneCancellationState(against: events)
            errorMessage = nil

            evaluateCountdownTrigger()
            onPollComplete?()
        } catch {
            errorMessage = error.localizedDescription
            diagnosticLog?.error(.calendar, "Poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Countdown Logic

    /// Check if any meeting is within any of the countdown thresholds.
    private func evaluateCountdownTrigger() {
        // For each meeting, check each configured countdown time. Cancelled
        // meetings are skipped — their reminders fire as a one-shot system
        // notification at detection time instead (see AppLifecycleManager).
        for event in upcomingMeetings where event.timeUntilStart > 0 && !event.isCancelled {
            for minutes in countdownMinutesList {
                let thresholdSeconds = TimeInterval(minutes * 60)
                let comboKey = "\(event.id)_\(minutes)"

                // Freshness gate: only fire if the threshold was crossed within the
                // last poll cycle (~60s grace). Without this, waking from sleep with a
                // meeting still ahead would dump every stale threshold ("15 min before")
                // even though those windows already passed during sleep.
                let secondsSinceCrossed = thresholdSeconds - event.timeUntilStart
                if event.timeUntilStart <= thresholdSeconds &&
                   secondsSinceCrossed <= 60 &&
                   !triggeredCombinations.contains(comboKey) {
                    triggeredCombinations.insert(comboKey)

                    // Consult the policy hook (if set) before showing the overlay. The
                    // hook reads live context — e.g., suppress while in another call.
                    let triggerConfig = countdownConfigs?.trigger(for: minutes)
                    let allowed: Bool
                    if let triggerConfig {
                        allowed = shouldFireOverlay?(triggerConfig) ?? triggerConfig.showOverlay
                    } else {
                        allowed = true
                    }
                    if allowed, !shouldShowCountdown {
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

        // Once the countdown meeting has ENDED, force-close the overlay — joining
        // is moot. While the meeting is merely in progress, the overlay stays up
        // with a negative countdown until the user joins or dismisses (v2.3.3).
        if let current = countdownMeeting, current.endDate.timeIntervalSinceNow <= 0 {
            shouldShowCountdown = false
            countdownMeeting = nil
        }
    }

    // MARK: - Cancellation helpers

    /// Mark a cancellation as notified so the next refresh doesn't re-fire the
    /// system notification. Persisted to UserDefaults.
    func markCancellationNotified(_ id: String) {
        notifiedCancellationIDs.insert(id)
        UserDefaults.standard.set(Array(notifiedCancellationIDs), forKey: Self.k_notifiedCancellations)
        // The pendingCancellations recompute happens on next refresh; nudge published
        // value so the menu bar dropdown updates immediately if the meeting is still
        // in the upcoming list.
        if let meeting = upcomingMeetings.first(where: { $0.id == id }), meeting.isCancelled,
           !dismissedCancellationIDs.contains(id) {
            if !pendingCancellations.contains(where: { $0.id == id }) {
                pendingCancellations.append(meeting)
            }
        }
    }

    /// User clicked "Dismiss" on a cancelled meeting badge. Persisted so the badge
    /// stays gone across app restarts.
    func dismissCancellation(_ id: String) {
        dismissedCancellationIDs.insert(id)
        UserDefaults.standard.set(Array(dismissedCancellationIDs), forKey: Self.k_dismissedCancellations)
        pendingCancellations.removeAll { $0.id == id }
    }

    /// Drop notified/dismissed entries whose meeting has already ended — keeps the
    /// UserDefaults sets bounded and prevents stale IDs from accumulating forever.
    private func pruneCancellationState(against events: [MeetingEvent]) {
        let now = Date()
        // Build a set of meeting IDs that still exist in the upcoming window AND
        // haven't ended yet. Any persisted ID outside this set is safe to drop.
        let liveIDs = Set(events.filter { $0.endDate > now }.map(\.id))
        let prunedNotified = notifiedCancellationIDs.intersection(liveIDs)
        let prunedDismissed = dismissedCancellationIDs.intersection(liveIDs)
        if prunedNotified != notifiedCancellationIDs {
            notifiedCancellationIDs = prunedNotified
            UserDefaults.standard.set(Array(prunedNotified), forKey: Self.k_notifiedCancellations)
        }
        if prunedDismissed != dismissedCancellationIDs {
            dismissedCancellationIDs = prunedDismissed
            UserDefaults.standard.set(Array(prunedDismissed), forKey: Self.k_dismissedCancellations)
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

    // MARK: - Event creation (Quick Add)

    /// Create an event from a Quick Add draft. v1 writes go through EventKit only,
    /// regardless of the active read provider — Graph write support needs an OAuth
    /// scope upgrade (Calendars.Read → ReadWrite) and is a later phase. Refreshes
    /// immediately so the Today view shows the new event without waiting for the
    /// next poll.
    func createEvent(from draft: EventDraft, calendarID: String?) async throws {
        try eventKitProvider.createEvent(from: draft, calendarID: calendarID)
        await refreshEvents()
    }

    /// Available EventKit calendars for the Quick Add target picker.
    func eventKitCalendars() async -> [CalendarInfo] {
        (try? await eventKitProvider.availableCalendars()) ?? []
    }
}
