import Combine
import Foundation

/// Decides what Margin says first, and how loudly.
///
/// Four rules, all from the spec, all of them limits rather than features:
/// - **Budget** — at most `foldedCornerBudget` folded corners a day. Everything else waits
///   on the ribbon.
/// - **Timing** — a page shows itself in the gap between meetings. Not mid-call, not
///   thirty seconds before one starts.
/// - **Decay** — a page ignored twice retires the watch behind it, and the inside cover
///   says so. This is the memory Clippy never had.
/// - **Receipts** — anything done silently is a tick on today's page, crossable for an
///   hour.
@MainActor
final class MarginNudgeEngine: ObservableObject {

    /// The page currently showing itself, if any.
    @Published private(set) var folded: MarginNudge?
    /// Marked and waiting — found next time the notebook is opened.
    @Published private(set) var onRibbon: [MarginNudge] = []
    @Published private(set) var watches: [WatchState] = []

    private var config: MarginConfig?
    private weak var calendarManager: CalendarManager?
    private weak var taskManager: TaskManager?
    private var log: DiagnosticLog?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Folded corners spent today, keyed by day so it resets on its own.
    private var spentDay: String {
        UserDefaults.standard.string(forKey: "margin_foldDay") ?? ""
    }
    private var spentToday: Int {
        get { spentDay == Self.today ? UserDefaults.standard.integer(forKey: "margin_foldCount") : 0 }
        set {
            UserDefaults.standard.set(Self.today, forKey: "margin_foldDay")
            UserDefaults.standard.set(newValue, forKey: "margin_foldCount")
        }
    }
    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    func attach(config: MarginConfig, calendarManager: CalendarManager,
                taskManager: TaskManager, log: DiagnosticLog?) {
        self.config = config
        self.calendarManager = calendarManager
        self.taskManager = taskManager
        self.log = log
        loadWatches()

        // Re-evaluate when the day changes shape, not on a fast clock: nothing here is
        // urgent, and a nudge engine that runs hot is a battery bug.
        calendarManager.$upcomingWeek
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    // MARK: Watches

    private static let defaults: [WatchState] = [
        WatchState(id: "backToBack", label: "Hold a break when the day is back-to-back", origin: .builtIn),
        WatchState(id: "unanswered", label: "Nudge about invitations you haven't answered", origin: .builtIn),
        WatchState(id: "noLink", label: "Flag a meeting with no join link", origin: .builtIn),
        WatchState(id: "dueToday", label: "Mention tasks due today", origin: .builtIn)
    ]

    private func loadWatches() {
        guard let data = UserDefaults.standard.data(forKey: "margin_watches"),
              let saved = try? JSONDecoder().decode([WatchState].self, from: data) else {
            watches = Self.defaults
            return
        }
        // Keep saved state, but pick up watches added in a later version.
        var merged = saved
        for watch in Self.defaults where !saved.contains(where: { $0.id == watch.id }) {
            merged.append(watch)
        }
        watches = merged
    }

    private func saveWatches() {
        guard let data = try? JSONEncoder().encode(watches) else { return }
        UserDefaults.standard.set(data, forKey: "margin_watches")
    }

    func setWatch(_ id: String, enabled: Bool) {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        watches[index].enabled = enabled
        // Turning it back on by hand clears the decay — the user has overruled it.
        if enabled { watches[index].retired = false; watches[index].ignores = 0 }
        saveWatches()
    }

    private func watch(_ id: String) -> WatchState? {
        watches.first { $0.id == id && $0.enabled && !$0.retired }
    }

    // MARK: Evaluation

    func evaluate() {
        guard let config, config.isEnabled, !config.banded else { folded = nil; return }
        guard let calendarManager else { return }

        let found = findings(calendarManager)
        // Ribbon items are simply the ones not loud enough to show themselves.
        onRibbon = found.filter { $0.volume == .ribbonOnly }

        guard folded == nil else { return }
        guard let candidate = found.first(where: { $0.volume == .foldedCorner }) else { return }
        guard spentToday < config.foldedCornerBudget else {
            log?.debug(.assistant, "Margin: folded-corner budget spent (\(spentToday)/\(config.foldedCornerBudget))")
            return
        }
        guard inAGap(calendarManager) else { return }

        spentToday += 1
        folded = candidate
        if let index = watches.firstIndex(where: { $0.id == candidate.watchID }) {
            watches[index].lastFired = Date()
            saveWatches()
        }
        log?.info(.assistant, "Margin: folded a corner — \(candidate.kicker) · \(candidate.body.prefix(60))")
    }

    /// A page shows itself **in a gap**: nothing running, and nothing about to start.
    private func inAGap(_ calendarManager: CalendarManager) -> Bool {
        if !calendarManager.meetingsCurrentlyRunning.isEmpty { return false }
        let soon = calendarManager.upcomingWeek.first {
            !$0.isCancelled && $0.startDate > Date() && $0.startDate.timeIntervalSinceNow < 300
        }
        return soon == nil
    }

    // MARK: What it watches

    private func findings(_ calendarManager: CalendarManager) -> [MarginNudge] {
        var found: [MarginNudge] = []
        let now = Date()
        let today = calendarManager.todaysMeetings.filter { !$0.isCancelled && !$0.isAllDay }

        // 1. Back-to-back: act first, tell you second — the slot would be gone otherwise.
        //    Proposed, not taken, because v1 has no autonomy to spend.
        if watch("backToBack") != nil, let run = Self.backToBackRun(today, now: now), run.count >= 3,
           let gapStart = Self.breakSlot(after: run, in: today) {
            found.append(MarginNudge(
                id: "backToBack-\(gapStart.timeIntervalSince1970)",
                watchID: "backToBack",
                volume: .foldedCorner,
                kicker: "\(run.count) back-to-back",
                body: "That's \(run.count) meetings without a gap. There's room at \(gapStart.formatted(date: .omitted, time: .shortened)) — shall I hold 30 minutes?",
                why: "No break between \(run.first!.startDate.formatted(date: .omitted, time: .shortened)) and \(run.last!.endDate.formatted(date: .omitted, time: .shortened)).",
                primary: ("Hold 30 minutes", { @MainActor [weak self] in
                    guard let manager = self?.calendarManager else { return "No calendar." }
                    var draft = EventDraft(title: "Break", startDate: gapStart,
                                           endDate: gapStart.addingTimeInterval(1800), parserUsed: .detector)
                    draft.notes = "Held by Margin."
                    try await manager.createEvent(from: draft, calendarID: nil)
                    return "Held 30 minutes at \(gapStart.formatted(date: .omitted, time: .shortened))."
                }),
                expires: gapStart))
        }

        // 2. Invitations you haven't answered. Only a folded corner where the app can
        //    actually answer it; otherwise it's a ribbon note, because offering a button
        //    that can't work is worse than staying quiet.
        if watch("unanswered") != nil {
            let unanswered = calendarManager.upcomingWeek.filter {
                !$0.isCancelled && $0.myResponse == .noResponse &&
                $0.startDate > now && $0.startDate.timeIntervalSinceNow < 86_400
            }
            if let next = unanswered.first {
                let canAnswer = calendarManager.canRespond(to: next)
                var primary: (label: String, action: @MainActor () async throws -> String)?
                if canAnswer {
                    primary = ("Accept", { [weak self] in
                        try await self?.calendarManager?.respond(to: next.id, status: .accepted)
                        return "Accepted \(next.title)."
                    })
                }
                let others = unanswered.count - 1
                var body = "\(next.title) starts \(next.startDate.formatted(date: .abbreviated, time: .shortened)) and you haven't replied."
                if others > 0 { body += " \(others) other invitation\(others == 1 ? "" : "s") also waiting." }
                found.append(MarginNudge(
                    id: "unanswered-\(next.id)",
                    watchID: "unanswered",
                    volume: canAnswer ? .foldedCorner : .ribbonOnly,
                    kicker: "Unanswered · \(next.startDate.formatted(date: .omitted, time: .shortened))",
                    body: body,
                    primary: primary,
                    secondaryLabel: "Not now",
                    expires: next.startDate))
            }
        }

        // 3. No join link. Ribbon only: Margin can't add one yet, and a page offering to
        //    would be a promise it can't keep.
        if watch("noLink") != nil,
           let soon = today.first(where: { $0.url == nil && $0.startDate > now && $0.startDate.timeIntervalSinceNow < 1800 }) {
            found.append(MarginNudge(
                id: "noLink-\(soon.id)",
                watchID: "noLink",
                volume: .ribbonOnly,
                kicker: "In \(max(1, Int(soon.startDate.timeIntervalSinceNow / 60))) minutes",
                body: "\(soon.title) has no join link on the invite.",
                expires: soon.startDate))
        }

        // 4. Tasks due today.
        if watch("dueToday") != nil, let taskManager {
            let due = taskManager.tasks.filter { task in
                guard !task.isCompleted, let date = task.dueDate else { return false }
                return Calendar.current.isDateInToday(date)
            }
            if !due.isEmpty {
                found.append(MarginNudge(
                    id: "dueToday-\(due.count)",
                    watchID: "dueToday",
                    volume: .ribbonOnly,
                    kicker: "Due today",
                    body: due.map(\.title).joined(separator: ", ") + "."))
            }
        }
        return found
    }

    /// The longest run of meetings from now on with less than 10 minutes between them.
    static func backToBackRun(_ meetings: [MeetingEvent], now: Date) -> [MeetingEvent]? {
        let upcoming = meetings.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
        guard upcoming.count >= 2 else { return nil }
        var best: [MeetingEvent] = []
        var run: [MeetingEvent] = [upcoming[0]]
        for meeting in upcoming.dropFirst() {
            if meeting.startDate.timeIntervalSince(run.last!.endDate) <= 600 {
                run.append(meeting)
            } else {
                if run.count > best.count { best = run }
                run = [meeting]
            }
        }
        if run.count > best.count { best = run }
        return best.count >= 2 ? best : nil
    }

    /// The first 30 minutes free after a run ends, within the same working day.
    static func breakSlot(after run: [MeetingEvent], in day: [MeetingEvent], calendar: Calendar = .current) -> Date? {
        guard let end = run.last?.endDate else { return nil }
        let later = day.filter { $0.startDate >= end }.sorted { $0.startDate < $1.startDate }
        guard let next = later.first else { return end }
        return next.startDate.timeIntervalSince(end) >= 1800 ? end : nil
    }

    // MARK: Outcome

    /// The page was acted on. That clears the decay: a watch that gets used is a watch
    /// that earns its place.
    func accepted(_ nudge: MarginNudge) {
        if let index = watches.firstIndex(where: { $0.id == nudge.watchID }) {
            watches[index].ignores = 0
            saveWatches()
        }
        folded = nil
    }

    /// Ignored or dismissed. Twice, and the watch goes quiet — and says so on the inside
    /// cover, so it never looks like the user switched it off.
    func ignored(_ nudge: MarginNudge) {
        if let index = watches.firstIndex(where: { $0.id == nudge.watchID }) {
            watches[index].ignores += 1
            if watches[index].ignores >= WatchState.decayLimit {
                watches[index].retired = true
                watches[index].enabled = false
                log?.info(.assistant, "Margin: retired watch \"\(watches[index].label)\" after \(WatchState.decayLimit) ignores")
            }
            saveWatches()
        }
        folded = nil
    }
}
