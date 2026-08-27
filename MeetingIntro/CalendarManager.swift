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

    /// Every meeting in the current overlay group — more than one when several start at
    /// the same time. `countdownMeeting` stays the top-ranked one so existing consumers
    /// are unchanged.
    @Published var countdownMeetings: [MeetingEvent] = []

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
    var shouldFireOverlay: ((CountdownTrigger, MeetingEvent) -> Bool)?

    /// RSVP gate: returns true if a meeting should be suppressed because the user
    /// declined / didn't respond (per their settings). Injected in
    /// `AppLifecycleManager.observe` from `SmartConfigManager` so CalendarManager
    /// stays free of a MeetingContext dependency. nil → never suppress.
    var responseGate: ((MeetingEvent) -> Bool)?

    /// Suppress reminders for an event Microsoft 365 says is gone or cancelled while
    /// macOS Calendar still lists it (`GraphVerifier`). Same shape and the same three
    /// gate sites as `responseGate` — keep them in sync.
    var upstreamGate: ((MeetingEvent) -> Bool)?

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

    /// Existing timed meetings that overlap the given window (Issue #10 — Quick Add
    /// conflict warning). Reuses the already-fetched `upcomingWeek`, so it needs no
    /// EventKit call; note it's bounded by the browse window (`upcomingDaysAhead` days),
    /// so a draft further out than that won't surface conflicts.
    func conflicts(start: Date, end: Date) -> [MeetingEvent] {
        upcomingWeek.filter { ev in
            !ev.isAllDay && !ev.isCancelled
                && ev.startDate < end && ev.endDate > start
        }
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
    /// Internal, not private: `GraphVerifier` uses it to cross-check Exchange events
    /// even while EventKit is the active provider.
    let graphProvider = GraphCalendarProvider()

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
    /// Pending debounced refresh from an EventKit change notification.
    private var changeRefreshTask: Task<Void, Never>?
    /// Trailing debounce for change-driven refreshes. Long enough to swallow a commit
    /// storm, short enough that granting calendar access still feels immediate.
    private static let changeRefreshDebounce: Double = 2.0
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
    /// Per-meeting dedup for the "why no reminder" diagnostic so it logs once, not every poll.
    private var loggedReminderSuppressions: Set<String> = []

    /// Cancellation IDs we've already fired a system notification for. Persisted to
    /// UserDefaults so a relaunch doesn't re-notify for the same cancellation.
    private(set) var notifiedCancellationIDs: Set<String> = []
    /// Cancellation IDs the user has dismissed from the menu bar badge.
    private(set) var dismissedCancellationIDs: Set<String> = []
    private static let k_notifiedCancellations = "notifiedCancellationIDs"
    private static let k_dismissedCancellations = "dismissedCancellationIDs"

    /// Meeting IDs the user chose to stop reminding for (Issue #15). Keyed by bare event
    /// id — dismissing one threshold's reminder kills ALL remaining thresholds for that
    /// event. Persisted so it survives relaunch; pruned when the meeting ends.
    @Published private(set) var dismissedReminderIDs: Set<String> = []
    private static let k_dismissedReminders = "dismissedReminderIDs"

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

    /// Several armed meetings came due at the same moment and only one was opened.
    /// `(opened, skipped)` — wired to a notification so the choice is never silent.
    var onAutoJoinClash: ((MeetingEvent, [MeetingEvent]) -> Void)?

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

    // MARK: - Time-change detection (Issue #5)

    /// Last-seen start time per meeting ID, so a moved meeting can be detected across
    /// polls. Persisted (JSON) so a move that lands while the app is closed is still
    /// caught on next launch. A meeting seen for the FIRST time only records a baseline —
    /// it never notifies (there's no prior to compare against, so no false "moved").
    private var knownStartTimes: [String: Date] = [:]
    /// Dedup keyed `"<id>_<newStartEpoch>"` so the same move notifies once, even across
    /// relaunch or repeated polls.
    private var notifiedTimeChanges: Set<String> = []
    private static let k_knownStartTimes = "knownStartTimes"
    private static let k_notifiedTimeChanges = "notifiedTimeChanges"
    /// Ignore sub-minute jitter; only a real reschedule should notify.
    private static let timeChangeMinDelta: TimeInterval = 60

    /// Fired when a still-upcoming meeting's start time moved beyond `timeChangeMinDelta`.
    /// Second arg is the previous start time. Armed auto-joins re-anchor automatically
    /// (they're keyed by ID and re-read the live start) — this is purely the heads-up.
    var onMeetingTimeChanged: ((MeetingEvent, Date) -> Void)?

    // MARK: - Lifecycle

    init() {
        updateProviderCalendarFilter()
        let d = UserDefaults.standard
        self.notifiedCancellationIDs = Set(d.stringArray(forKey: Self.k_notifiedCancellations) ?? [])
        self.dismissedCancellationIDs = Set(d.stringArray(forKey: Self.k_dismissedCancellations) ?? [])
        self.dismissedReminderIDs = Set(d.stringArray(forKey: Self.k_dismissedReminders) ?? [])
        self.armedAutoJoinIDs = Set(d.stringArray(forKey: Self.k_armedAutoJoin) ?? [])
        self.joinedAutoJoinIDs = Set(d.stringArray(forKey: Self.k_joinedAutoJoin) ?? [])
        if let data = d.data(forKey: Self.k_knownStartTimes),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.knownStartTimes = decoded
        }
        self.notifiedTimeChanges = Set(d.stringArray(forKey: Self.k_notifiedTimeChanges) ?? [])
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
                Task { @MainActor [weak self] in self?.scheduleChangeDrivenRefresh() }
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

    /// Coalesce `EKEventStoreChanged`-driven refreshes.
    ///
    /// Every mirror commit — and every edit made in Calendar.app, or by any other app —
    /// posts this notification, and each one used to trigger an immediate full fetch
    /// (30 events + 21 mirror copies in one observed log) which then re-ran the whole
    /// reminder fan-out and another mirror reconcile. Measured 2026-08-27: **62 refreshes
    /// landed under 25s after the previous one**, against a 30s poll cadence.
    ///
    /// A short trailing debounce collapses a burst into one refresh while keeping the
    /// property this observer exists for: granting calendar access still updates the app
    /// within a couple of seconds, no restart needed.
    private func scheduleChangeDrivenRefresh() {
        changeRefreshTask?.cancel()
        changeRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.changeRefreshDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshEvents()
        }
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
            // Detect moved meetings over the wider browse window (catches a move from
            // a few days out, not just inside the reminder window).
            detectTimeChanges(in: allEvents)
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
        // Auto-dismiss the in-progress overlay FIRST, every poll, before the trigger
        // loop below can early-return. Close it once the meeting has ENDED, OR once it
        // has been in progress past the configured cap (a long meeting must not pin the
        // overlay for its whole duration — a real report had one stranded ~12h and go
        // unresponsive). Running this ahead of the loop also frees the single overlay
        // slot so a later meeting's reminder isn't silently swallowed. (v2.3.3 kept this
        // at the end of the function, after a `return` — so on a busy/long meeting it
        // never ran; that was the latent bug.)
        if let current = countdownMeeting {
            let capMinutes = countdownConfigs?.inProgressOverlayMaxMinutes ?? 15
            let secondsSinceStart = -current.startDate.timeIntervalSinceNow // > 0 after start
            let ended = current.endDate.timeIntervalSinceNow <= 0
            let cappedInProgress = capMinutes > 0 && secondsSinceStart >= TimeInterval(capMinutes * 60)
            if ended || cappedInProgress {
                diagnosticLog?.info(.overlay, "Auto-dismissed countdown overlay — \"\(current.title)\" (\(ended ? "meeting ended" : "in progress > \(capMinutes)m cap"))")
                shouldShowCountdown = false
                countdownMeeting = nil
            }
        }

        // Diagnostic: for any meeting now inside the largest reminder window, log ONCE
        // why it will NOT fire a reminder (the overlay/notification gates are otherwise
        // silent — this is the "why didn't my overlay show?" trail).
        let maxThresholdSeconds = TimeInterval((countdownMinutesList.max() ?? 0) * 60)
        for event in upcomingMeetings where event.timeUntilStart > 0 && event.timeUntilStart <= maxThresholdSeconds {
            let reason: String?
            if event.isCancelled {
                reason = "marked CANCELLED (EventKit status .canceled or a \"Canceled:\"/\"Cancelled:\" title) — verify it isn't actually cancelled in Calendar"
            } else if upstreamGate?(event) ?? false {
                reason = "Microsoft 365 says this meeting is cancelled or no longer exists — macOS Calendar is out of date"
            } else if responseGate?(event) ?? false {
                reason = "RSVP gate (you declined / didn't respond, with the skip setting on)"
            } else if armedAutoJoinIDs.contains(event.id) {
                reason = "armed for auto-join (shows a menu-bar countdown instead of the overlay)"
            } else if dismissedReminderIDs.contains(event.id) {
                reason = "dismissed by user (you chose to stop reminders for this event)"
            } else {
                reason = nil
            }
            if let reason {
                let key = "\(event.id)_nofire"
                if loggedReminderSuppressions.insert(key).inserted {
                    diagnosticLog?.info(.reminder, "No reminder will fire for \"\(event.title)\" — \(reason)")
                }
            }
        }

        // For each meeting, check each configured countdown time. Cancelled
        // meetings are skipped — their reminders fire as a one-shot system
        // notification at detection time instead (see AppLifecycleManager).
        // Collect EVERY meeting whose threshold crosses in this pass, not just the first.
        // Meetings that start together are a real case (back-to-back standups, a
        // double-booking) and the old code fired the first one and `return`ed — the
        // others were marked triggered on a later poll and then rejected by the
        // "overlay already showing" check, so they were never shown and never retried.
        // `ConcurrentOverlayStyle` decides how the group is presented.
        var firingNow: [MeetingEvent] = []
        for event in upcomingMeetings where event.timeUntilStart > 0 && !event.isCancelled && !(responseGate?(event) ?? false) && !(upstreamGate?(event) ?? false) && !armedAutoJoinIDs.contains(event.id) && !dismissedReminderIDs.contains(event.id) {
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
                        allowed = shouldFireOverlay?(triggerConfig, event) ?? triggerConfig.showOverlay
                    } else {
                        allowed = true
                    }
                    if allowed { firingNow.append(event) }
                    break // this event has fired; don't also fire its other thresholds
                }
            }
        }

        // Show the group as one overlay event. An overlay that's already up wins — we
        // don't yank it out from under the user mid-read (same as the previous
        // behaviour); the thresholds are marked triggered either way.
        if !firingNow.isEmpty, !shouldShowCountdown {
            let group = Self.rankedForOverlay(firingNow)
            countdownMeetings = group
            countdownMeeting = group.first
            nextMeeting = group.first
            shouldShowCountdown = true
            if group.count > 1 {
                diagnosticLog?.info(.overlay, "\(group.count) meetings start together — showing \(group.map(\.title).joined(separator: ", "))")
            }
        }

        // Update nextMeeting to the soonest future meeting
        nextMeeting = upcomingMeetings.first { $0.timeUntilStart > 0 }
        // (The in-progress/ended overlay auto-dismiss now runs at the TOP of this
        // function so an early `return` in the trigger loop can't skip it.)
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

    /// User chose "stop reminding me for this event" (Issue #15) — suppresses every
    /// remaining threshold for the event, across both the overlay and notification/voice
    /// gates. Persisted.
    func dismissReminders(_ id: String) {
        guard !dismissedReminderIDs.contains(id) else { return }
        dismissedReminderIDs.insert(id)
        UserDefaults.standard.set(Array(dismissedReminderIDs), forKey: Self.k_dismissedReminders)
        if let meeting = upcomingMeetings.first(where: { $0.id == id }) {
            diagnosticLog?.info(.reminder, "Reminders dismissed by user for \"\(meeting.title)\" — no further thresholds will fire")
        }
    }

    /// Re-enable reminders for an event the user previously dismissed.
    func undismissReminders(_ id: String) {
        guard dismissedReminderIDs.contains(id) else { return }
        dismissedReminderIDs.remove(id)
        UserDefaults.standard.set(Array(dismissedReminderIDs), forKey: Self.k_dismissedReminders)
    }

    func remindersDismissed(_ id: String) -> Bool { dismissedReminderIDs.contains(id) }

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
        // Same bounding for the reminder-dismiss set (Issue #15).
        let prunedReminders = dismissedReminderIDs.intersection(liveIDs)
        if prunedReminders != dismissedReminderIDs {
            dismissedReminderIDs = prunedReminders
            UserDefaults.standard.set(Array(prunedReminders), forKey: Self.k_dismissedReminders)
        }
    }

    // MARK: - Time-change detection (Issue #5)

    /// Compare each still-upcoming meeting's start against the last-seen value, notify
    /// once per move (beyond the min delta), and refresh the baselines. First-sight
    /// meetings only record a baseline — they never notify. Cancelled + all-day events
    /// are skipped (cancellation has its own channel; all-day moves aren't "got dressed
    /// for nothing" cases). Safe across transient absences: a dropped-then-reappearing
    /// meeting is treated as first-sight, so the worst case is a missed notice, never a
    /// false one.
    private func detectTimeChanges(in events: [MeetingEvent]) {
        let now = Date()
        var dirty = false
        for event in events where !event.isCancelled && !event.isAllDay && event.startDate > now {
            // Baseline key. Non-recurring: the event id. Recurring: id + occurrenceDate —
            // every occurrence of a series shares ONE id, so an id-keyed baseline would
            // false-fire as occurrences roll over. occurrenceDate is the occurrence's
            // ORIGINAL slot and stays fixed even when it's moved, giving each occurrence
            // a stable key AND letting a moved occurrence be detected (its startDate
            // diverges from the baseline). A recurring event with no occurrenceDate
            // (e.g. the Graph provider, which doesn't expose it) stays skipped.
            let baselineKey: String
            if event.isRecurring {
                guard let occ = event.occurrenceDate else { continue }
                baselineKey = "\(event.id)\u{1F}\(Int(occ.timeIntervalSince1970))"
            } else {
                baselineKey = event.id
            }
            if let prior = knownStartTimes[baselineKey],
               abs(prior.timeIntervalSince(event.startDate)) >= Self.timeChangeMinDelta {
                let key = "\(baselineKey)_\(Int(event.startDate.timeIntervalSince1970))"
                if notifiedTimeChanges.insert(key).inserted {
                    diagnosticLog?.info(.calendar, "Meeting moved — \"\(event.title)\": \(prior.formatted(date: .abbreviated, time: .shortened)) → \(event.startDate.formatted(date: .abbreviated, time: .shortened))")
                    onMeetingTimeChanged?(event, prior)
                    dirty = true
                }
            }
            if knownStartTimes[baselineKey] != event.startDate {
                knownStartTimes[baselineKey] = event.startDate
                dirty = true
            }
        }
        if pruneTimeChangeState(against: events) { dirty = true }
        if dirty { persistTimeChangeState() }
    }

    /// Drop baselines/dedup keys for meetings no longer in the fetch window. Returns
    /// whether anything changed (so the caller can persist).
    @discardableResult
    private func pruneTimeChangeState(against events: [MeetingEvent]) -> Bool {
        let liveIDs = Set(events.map(\.id))
        var changed = false
        // Keys are either a bare event id (non-recurring) or "id\u{1F}occurrenceEpoch"
        // (recurring). Keep a key if its id part is still live.
        let prunedKnown = knownStartTimes.filter { entry in
            liveIDs.contains(entry.key) || liveIDs.contains { entry.key.hasPrefix("\($0)\u{1F}") }
        }
        if prunedKnown.count != knownStartTimes.count { knownStartTimes = prunedKnown; changed = true }
        // Notified keys are "id_newStart" (non-recurring) or "id\u{1F}occ_newStart" (recurring).
        let prunedNotified = notifiedTimeChanges.filter { key in
            liveIDs.contains { key.hasPrefix("\($0)_") || key.hasPrefix("\($0)\u{1F}") }
        }
        if prunedNotified.count != notifiedTimeChanges.count { notifiedTimeChanges = prunedNotified; changed = true }
        return changed
    }

    private func persistTimeChangeState() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(knownStartTimes) {
            d.set(data, forKey: Self.k_knownStartTimes)
        }
        d.set(Array(notifiedTimeChanges), forKey: Self.k_notifiedTimeChanges)
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

        // Meetings opened in THIS tick. Three armed meetings coming due together used to
        // open three links at once, which is not a usable way to start a meeting: unless
        // the user opted into `autoJoinOpensAllOnClash`, the first (top-ranked) one wins
        // and the rest are reported instead of opened. They're still marked joined so
        // they can't spring open a moment later.
        var openedThisTick: MeetingEvent?
        var skippedThisTick: [MeetingEvent] = []
        let opensAll = countdownConfigs?.autoJoinOpensAllOnClash ?? false

        // Iterate in rank order so the meeting that wins a clash is the one you're most
        // likely to attend, not whichever the Set happened to yield first. Armed ids with
        // no meeting in the current window are simply absent here — they stay armed.
        let armedMeetings = Self.rankedForOverlay(armedAutoJoinIDs.compactMap { armedID in
            upcomingMeetings.first { $0.id == armedID }
        })
        for meeting in armedMeetings {
            let id = meeting.id

            if meeting.isCancelled {
                diagnosticLog?.info(.overlay, "Auto-join cancelled (meeting cancelled) — \(meeting.title)")
                disarmAutoJoin(id)
                continue
            }
            // The exact failure this whole verifier exists for: a phantom meeting that
            // armed auto-join and opened a Zoom nobody was in.
            if upstreamGate?(meeting) ?? false {
                diagnosticLog?.warn(.overlay, "Auto-join cancelled — Microsoft 365 no longer has \"\(meeting.title)\"")
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

            // A clash: something was already opened this tick and the user hasn't asked
            // for all of them. Mark it joined (so it can't open later) and report it.
            if !opensAll, openedThisTick != nil {
                diagnosticLog?.info(.overlay, "Auto-join held back (another meeting opened this tick) — \(meeting.title)")
                skippedThisTick.append(meeting)
                joinedAutoJoinIDs.insert(id)
                armedAutoJoinIDs.remove(id)
                persistAutoJoinState()
                continue
            }

            // Fire: open the link exactly once. Explicit user intent — fires regardless
            // of smart-context suppression, but the notification keeps it from being silent.
            diagnosticLog?.info(.overlay, "Auto-join firing — opening \(meeting.title)")
            NSWorkspace.shared.open(url)
            openedThisTick = meeting
            joinedAutoJoinIDs.insert(id)
            armedAutoJoinIDs.remove(id)
            persistAutoJoinState()
            // The overlay was dismissed at arm time; close defensively if it's still up.
            if countdownMeeting?.id == id { dismissCountdown() }
            onAutoJoinFired?(meeting)
        }
        if let opened = openedThisTick, !skippedThisTick.isEmpty {
            diagnosticLog?.info(.overlay, "Auto-join clash — opened \(opened.title), held back \(skippedThisTick.map(\.title).joined(separator: ", "))")
            onAutoJoinClash?(opened, skippedThisTick)
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

    /// Order a group of simultaneous meetings for the overlay. The first is the "hero"
    /// in the styles that have one. Ranking: the meeting you accepted (or own) first,
    /// then one with a join link, then the earliest start, then title for stability —
    /// i.e. the one you're most likely to actually attend leads.
    static func rankedForOverlay(_ meetings: [MeetingEvent]) -> [MeetingEvent] {
        meetings.sorted { a, b in
            let aCommitted = a.myResponse == .accepted || a.myResponse == .organizer
            let bCommitted = b.myResponse == .accepted || b.myResponse == .organizer
            if aCommitted != bCommitted { return aCommitted }
            if (a.url != nil) != (b.url != nil) { return a.url != nil }
            if a.startDate != b.startDate { return a.startDate < b.startDate }
            return a.title < b.title
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
