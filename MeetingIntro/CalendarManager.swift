import AppKit
import Combine
import EventKit
import Foundation

/// Orchestrates calendar event polling using the active calendar provider.
/// Publishes upcoming meetings and triggers countdown when threshold is reached.
@MainActor
final class CalendarManager: ObservableObject {

    // MARK: - Published State

    /// All upcoming meetings from the active provider (reminder-scoped window).
    @Published var upcomingMeetings: [MeetingEvent] = []

    /// A wider window (default 7 days) for the menu-bar "upcoming days" browser. Same
    /// fetch as `upcomingMeetings`, just not filtered down to the reminder window — so
    /// the future-date views have data without touching the reminder/cancellation paths.
    @Published var upcomingWeek: [MeetingEvent] = []

    /// Timestamp of the last successful refresh — surfaced as "synced Xm ago" in the
    /// menu-bar popover header. (`lastPollDate` is private + also tracks failed/catch-up
    /// polls; this is the public, success-only signal.)
    @Published private(set) var lastRefreshDate: Date?

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

    /// RSVP gate: returns true if a meeting should be suppressed because the user
    /// declined / didn't respond (per their settings). Injected in
    /// `AppLifecycleManager.observe` from `SmartConfigManager` so CalendarManager
    /// stays free of a MeetingContext dependency. nil → never suppress.
    var responseGate: ((MeetingEvent) -> Bool)?

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

    /// How many days ahead the upcoming-days browser loads (1–30, default 7).
    var upcomingDaysAhead: Int {
        let stored = UserDefaults.standard.object(forKey: "upcomingDaysAhead") as? Int ?? 7
        return max(1, min(30, stored))
    }

    /// Future days (excluding today), each with its events sorted by start, for the
    /// menu-bar browser. Empty days are omitted. Cancelled meetings are included so the
    /// user sees them struck-through, mirroring the today list.
    func upcomingDaySchedules() -> [(date: Date, events: [MeetingEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: upcomingWeek.filter { !cal.isDateInToday($0.startDate) && $0.startDate > Date() }) {
            cal.startOfDay(for: $0.startDate)
        }
        return grouped.keys.sorted().map { day in
            (date: day, events: grouped[day]!.sorted { $0.startDate < $1.startDate })
        }
    }

    /// Events for a single calendar day (used by the popover day-navigator). Includes
    /// today; sorted by start.
    func events(on day: Date) -> [MeetingEvent] {
        let cal = Calendar.current
        return upcomingWeek
            .filter { cal.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
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
    private var wakeObserver: NSObjectProtocol?

    /// Timestamp of the previous poll. A large gap means the Mac was asleep (the
    /// 30s timer doesn't fire during sleep), so the next poll is a "catch-up".
    private var lastPollDate: Date?
    /// True for the duration of a catch-up poll (gap > 90s since the last poll).
    /// Read by the reminder fan-out so a reminder whose window fell during sleep
    /// still fires on wake — but collapsed to the single most-imminent threshold.
    private(set) var lastPollWasCatchUp = false
    /// Tracks which (meetingID, minutesBefore) combos have already been triggered.
    private var triggeredCombinations: Set<String> = []

    /// Cancellation IDs we've already fired a system notification for. Persisted to
    /// UserDefaults so a relaunch doesn't re-notify for the same cancellation.
    private(set) var notifiedCancellationIDs: Set<String> = []
    /// Cancellation IDs the user has dismissed from the menu bar badge.
    private(set) var dismissedCancellationIDs: Set<String> = []
    private static let k_notifiedCancellations = "notifiedCancellationIDs"
    private static let k_dismissedCancellations = "dismissedCancellationIDs"

    // MARK: - Auto-join ("Start at Time", Issue #2)

    /// Meeting IDs the user armed for auto-join from the countdown overlay. Persisted
    /// so a relaunch shortly before the meeting still honors the arm. Published so the
    /// menu bar can show + offer to disarm them. Keyed by ID only — the live event's
    /// `startDate`/`url` are re-read each poll, so a reschedule or link change is tracked.
    @Published private(set) var armedAutoJoinIDs: Set<String> = []
    /// Meeting IDs whose auto-join has already fired — de-dup so the 30s poll doesn't
    /// re-open the link every cycle after the start time passes.
    private var joinedAutoJoinIDs: Set<String> = []
    private static let k_armedAutoJoin = "armedAutoJoinIDs"
    private static let k_joinedAutoJoin = "joinedAutoJoinIDs"

    /// Fired when the user arms a meeting (for the confirmation notification).
    var onAutoJoinArmed: ((MeetingEvent) -> Void)?
    /// Fired the moment an armed meeting's link is auto-opened.
    var onAutoJoinFired: ((MeetingEvent) -> Void)?
    /// Fired when an armed meeting's start passed beyond the freshness window (e.g. the
    /// Mac slept through it) — the join is NOT performed; the user is told instead.
    var onAutoJoinMissed: ((MeetingEvent) -> Void)?

    /// Armed meetings still upcoming/in-progress (for the menu bar disarm list).
    var armedAutoJoinMeetings: [MeetingEvent] {
        upcomingMeetings
            .filter { armedAutoJoinIDs.contains($0.id) && !$0.isCancelled && $0.endDate > Date() }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Freshness bound for auto-join, in minutes (from config; default 2). Clamped to
    /// ≥1 — a 0-minute window combined with the 30s poll would always read as "missed".
    private var autoJoinGraceMinutes: Int {
        max(1, countdownConfigs?.autoJoinGraceMinutes ?? 2)
    }

    // MARK: - Lifecycle

    init() {
        updateProviderCalendarFilter()
        let d = UserDefaults.standard
        self.notifiedCancellationIDs = Set(d.stringArray(forKey: Self.k_notifiedCancellations) ?? [])
        self.dismissedCancellationIDs = Set(d.stringArray(forKey: Self.k_dismissedCancellations) ?? [])
        self.armedAutoJoinIDs = Set(d.stringArray(forKey: Self.k_armedAutoJoin) ?? [])
        self.joinedAutoJoinIDs = Set(d.stringArray(forKey: Self.k_joinedAutoJoin) ?? [])
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

        // Re-poll immediately on wake rather than waiting up to 30s for the next
        // timer tick. The refresh sees a large gap since the last poll and runs as a
        // catch-up (firing the most-imminent reminder missed during sleep).
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshEvents() }
            }
        }

        // Also fetch immediately
        Task { await refreshEvents() }
    }

    /// On a catch-up poll (post-sleep), the single most-imminent enabled threshold a
    /// still-upcoming meeting has already crossed — the one reminder worth firing
    /// late. Returns nil on normal polls or when nothing applies. Collapsing to the
    /// minimum avoids waking to a stack of every backed-up threshold (15/10/5/2 min).
    func catchUpThresholdMinutes(for event: MeetingEvent) -> Int? {
        guard lastPollWasCatchUp, event.timeUntilStart > 0, !event.isCancelled else { return nil }
        return countdownMinutesList
            .filter { event.timeUntilStart <= TimeInterval($0 * 60) }
            .min()
    }

    /// Stop polling.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Event Fetching

    /// Refresh events from the active provider.
    func refreshEvents() async {
        // Detect a catch-up poll: a gap far larger than the 30s timer interval means
        // the Mac was asleep (timers don't fire during sleep). Set this BEFORE
        // assigning `upcomingMeetings` so the reminder fan-out sink reads the right
        // value. A reminder whose window fell during sleep is otherwise dropped by
        // the freshness gate; on a catch-up poll we let the single most-imminent one
        // through (see `catchUpThresholdMinutes`).
        let now0 = Date()
        if let last = lastPollDate {
            lastPollWasCatchUp = now0.timeIntervalSince(last) > 90
        }
        lastPollDate = now0

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

            // Fetch a WIDER window (for the upcoming-days browser) in a single call,
            // then derive `upcomingMeetings` by filtering back to the original reminder
            // window — so every reminder/cancellation/auto-join consumer behaves exactly
            // as before, and only the browsing UI sees the extra days.
            let reminderWindow = lookAheadInterval
            let browseWindow = max(reminderWindow, TimeInterval(upcomingDaysAhead) * 86400)
            let allEvents = try await activeProvider.fetchUpcomingEvents(within: browseWindow)
            let now = Date()
            let reminderWindowEnd = now.addingTimeInterval(reminderWindow)
            let events = allEvents.filter { $0.startDate <= reminderWindowEnd }
            upcomingMeetings = events
            upcomingWeek = allEvents
            diagnosticLog?.debug(.calendar, "Poll: \(events.count) in reminder window, \(allEvents.count) in \(upcomingDaysAhead)-day browse window (\(activeProviderType.rawValue))")
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
            pruneAutoJoinState(against: events)
            errorMessage = nil
            lastRefreshDate = now

            evaluateCountdownTrigger()
            evaluateAutoJoin()
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
        for event in upcomingMeetings where event.timeUntilStart > 0 && !event.isCancelled && !(responseGate?(event) ?? false) && !armedAutoJoinIDs.contains(event.id) {
            for minutes in countdownMinutesList {
                let thresholdSeconds = TimeInterval(minutes * 60)
                let comboKey = "\(event.id)_\(minutes)"

                // Freshness gate: only fire if the threshold was crossed within the
                // last poll cycle (~60s grace). Without this, waking from sleep with a
                // meeting still ahead would dump every stale threshold ("15 min before")
                // even though those windows already passed during sleep.
                let secondsSinceCrossed = thresholdSeconds - event.timeUntilStart
                // Normal poll: fire only the threshold crossed within the last cycle.
                // Catch-up poll (post-sleep): also fire the most-imminent threshold
                // missed during sleep, even though it crossed more than 60s ago.
                let freshlyCrossed = secondsSinceCrossed <= 60
                let catchUp = catchUpThresholdMinutes(for: event) == minutes
                if event.timeUntilStart <= thresholdSeconds &&
                   (freshlyCrossed || catchUp) &&
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

    // MARK: - Auto-join ("Start at Time")

    /// Arm a meeting for auto-join. Called from the overlay's "Start at Time" button.
    /// Idempotent; persists so a relaunch shortly before start still honors it.
    func armAutoJoin(_ id: String) {
        // Only arm real meetings in the current window — guards against the Settings
        // "Test Countdown Overlay" preview (a synthetic "test" event) persisting a
        // phantom armed ID, and against arming something we can't later evaluate.
        guard let meeting = upcomingMeetings.first(where: { $0.id == id }) else { return }
        guard !armedAutoJoinIDs.contains(id) else { return }
        // Re-arming after a prior fire should start fresh.
        joinedAutoJoinIDs.remove(id)
        armedAutoJoinIDs.insert(id)
        persistAutoJoinState()
        diagnosticLog?.info(.overlay, "Auto-join armed — \(meeting.title) @ \(meeting.formattedStartTime)")
        onAutoJoinArmed?(meeting)
    }

    /// "Join now" from the heads-up overlay: open the link immediately and disarm.
    func joinNowAndDisarm(_ id: String) {
        if let meeting = upcomingMeetings.first(where: { $0.id == id }), let url = meeting.url {
            diagnosticLog?.info(.overlay, "Auto-join: Join now tapped — \(meeting.title)")
            NSWorkspace.shared.open(url)
        }
        disarmAutoJoin(id)
    }

    /// Disarm a meeting (user clicked the menu bar disarm row, or it became moot).
    func disarmAutoJoin(_ id: String) {
        guard armedAutoJoinIDs.contains(id) else { return }
        armedAutoJoinIDs.remove(id)
        persistAutoJoinState()
        if let meeting = upcomingMeetings.first(where: { $0.id == id }) {
            diagnosticLog?.info(.overlay, "Auto-join disarmed — \(meeting.title)")
        }
    }

    /// For each armed meeting that has reached its start time, open its conference link
    /// once (as if the user hit Join). Runs on every poll.
    ///
    /// Guardrails (Issue #2 risk analysis):
    /// - **Freshness bound**: fire only if `now <= startDate + grace`. Past that — e.g.
    ///   the Mac slept through the start (the 30s poll is suspended during sleep) — the
    ///   join is treated as *missed* rather than yanking the user into a long-started
    ///   meeting. (Bound is time-based, so it covers the catch-up/wake poll uniformly.)
    /// - **Cancelled**: never auto-join; disarm.
    /// - **No link**: never auto-join; disarm (the button is link-gated, but the link
    ///   can vanish between arm and start).
    /// - **De-dup**: `joinedAutoJoinIDs` guarantees a single open.
    ///
    /// Internal (not private) so the 1-second menu-bar countdown ticker can drive it too
    /// — the 30s poll alone would open the link up to ~30s after the displayed 0:00,
    /// which reads as broken. Idempotent + de-duped, so calling it every second is safe.
    func evaluateAutoJoin() {
        guard !armedAutoJoinIDs.isEmpty else { return }
        let now = Date()
        let grace = TimeInterval(autoJoinGraceMinutes * 60)

        for id in armedAutoJoinIDs {
            // Not in the current window yet (e.g. armed across a long gap) — leave armed.
            guard let meeting = upcomingMeetings.first(where: { $0.id == id }) else { continue }

            if meeting.isCancelled {
                diagnosticLog?.info(.overlay, "Auto-join cancelled (meeting cancelled) — \(meeting.title)")
                disarmAutoJoin(id)
                continue
            }
            guard let url = meeting.url else {
                diagnosticLog?.warn(.overlay, "Auto-join skipped (no join link) — \(meeting.title)")
                disarmAutoJoin(id)
                continue
            }

            // Not started yet — wait.
            if now < meeting.startDate { continue }

            // Already ended, or started too long ago (slept through) → missed, don't open.
            if now >= meeting.endDate || now > meeting.startDate.addingTimeInterval(grace) {
                diagnosticLog?.warn(.overlay, "Auto-join missed (started \(Int(now.timeIntervalSince(meeting.startDate) / 60))m ago, beyond \(autoJoinGraceMinutes)m grace) — \(meeting.title)")
                joinedAutoJoinIDs.insert(id)
                armedAutoJoinIDs.remove(id)
                persistAutoJoinState()
                onAutoJoinMissed?(meeting)
                continue
            }

            guard !joinedAutoJoinIDs.contains(id) else {
                armedAutoJoinIDs.remove(id); persistAutoJoinState(); continue
            }

            // Fire: open the link exactly once. Explicit user intent — fires regardless
            // of smart-context suppression, but the notification keeps it from being silent.
            diagnosticLog?.info(.overlay, "Auto-join firing — opening \(meeting.title)")
            NSWorkspace.shared.open(url)
            joinedAutoJoinIDs.insert(id)
            armedAutoJoinIDs.remove(id)
            persistAutoJoinState()
            // The overlay was dismissed at arm time; close defensively if it's still up.
            if countdownMeeting?.id == id { dismissCountdown() }
            onAutoJoinFired?(meeting)
        }
    }

    private func persistAutoJoinState() {
        UserDefaults.standard.set(Array(armedAutoJoinIDs), forKey: Self.k_armedAutoJoin)
        UserDefaults.standard.set(Array(joinedAutoJoinIDs), forKey: Self.k_joinedAutoJoin)
    }

    /// Keep the armed/joined sets bounded. Conservatively drop an *armed* ID only when
    /// its meeting is present in this fetch AND has ended — a transient fetch that
    /// momentarily omits an imminent meeting must NOT silently un-arm it (that arm is
    /// about to fire). `joinedAutoJoinIDs` is terminal bookkeeping, so it's pruned to
    /// the live window outright.
    private func pruneAutoJoinState(against events: [MeetingEvent]) {
        let now = Date()
        let endedIDs = Set(events.filter { $0.endDate <= now }.map(\.id))
        let liveIDs = Set(events.filter { $0.endDate > now }.map(\.id))
        let prunedArmed = armedAutoJoinIDs.subtracting(endedIDs)
        let prunedJoined = joinedAutoJoinIDs.intersection(liveIDs)
        if prunedArmed != armedAutoJoinIDs || prunedJoined != joinedAutoJoinIDs {
            armedAutoJoinIDs = prunedArmed
            joinedAutoJoinIDs = prunedJoined
            persistAutoJoinState()
        }
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

    // MARK: - RSVP

    /// Whether the active provider can write an RSVP response (Graph, write-scoped).
    var supportsRSVPWrite: Bool { activeProvider.supportsResponding }

    /// Respond to an invitation, then refresh so the new status shows immediately.
    func respond(to eventID: String, status: ResponseStatus) async throws {
        do {
            try await activeProvider.respond(to: eventID, status: status)
            diagnosticLog?.info(.calendar, "RSVP \(status.rawValue) sent for event \(eventID)")
        } catch {
            diagnosticLog?.error(.calendar, "RSVP \(status.rawValue) failed: \(error.localizedDescription)")
            throw error
        }
        await refreshEvents()
    }
}
