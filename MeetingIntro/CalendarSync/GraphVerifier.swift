import Combine
import Foundation

/// Checks Exchange-backed events that macOS reports against what Microsoft 365 actually
/// says, and flags the ones the server no longer has.
///
/// **The bug this exists for.** macOS Calendar's Exchange sync can fail to apply a
/// change and leave a phantom behind. A user had a meeting cancelled a week earlier that
/// macOS still showed; MeetingIntro faithfully reminded him, he armed auto-join from the
/// overlay, and the app opened a Zoom for a meeting that did not exist. Nothing in
/// EventKit distinguishes that event from a real one — `status` is not `.canceled`, the
/// title carries no prefix — so no amount of local logic can catch it. A second opinion
/// is the only fix.
///
/// **Deliberately a verifier, not a provider switch.** The app runs one calendar provider
/// at a time, so switching to Graph would drop every non-Exchange calendar the user keeps
/// in macOS Calendar. EventKit stays the source of truth for what to *show*; Graph is
/// consulted only to answer "does the server still have this?" for Exchange events.
///
/// **Every rail here points the same way: never suppress a real meeting.**
/// - A failed or empty Graph fetch aborts the whole run. Treating "Graph returned
///   nothing" as "everything is cancelled" would silence a user's entire day.
/// - Only events on Exchange-backed calendars are considered; anything else is untouched.
/// - A suppressing verdict needs **two consecutive runs agreeing**, so one bad response
///   can't silence a meeting. `.confirmed` applies immediately — clearing a suppression
///   fast is the safe direction.
/// - An event just created locally hasn't synced upstream yet, which looks identical to a
///   phantom. The two-run rule plus the run interval gives it several minutes of grace.
@MainActor
final class GraphVerifier: ObservableObject {

    enum Verdict: Equatable {
        /// Microsoft 365 has it and it isn't cancelled.
        case confirmed
        /// Microsoft 365 has it and marks it cancelled, while macOS still shows it live.
        case cancelledUpstream
        /// Microsoft 365 doesn't have it at all — the phantom case.
        case absentUpstream

        var suppressesReminders: Bool { self != .confirmed }

        var shortReason: String {
            switch self {
            case .confirmed:        return "confirmed on Microsoft 365"
            case .cancelledUpstream: return "cancelled on Microsoft 365 (macOS Calendar is out of date)"
            case .absentUpstream:    return "no longer on Microsoft 365 (macOS Calendar is out of date)"
            }
        }
    }

    /// EventKit event id → verdict, for verdicts that have survived the two-run rule.
    @Published private(set) var verdicts: [String: Verdict] = [:]
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastError: String?

    /// Verdicts seen on the most recent run, awaiting a second agreeing run.
    private var provisional: [String: Verdict] = [:]

    private weak var calendarManager: CalendarManager?
    private weak var graphProvider: GraphCalendarProvider?
    private var config: GraphVerifierConfig?
    private var diagnosticLog: DiagnosticLog?
    private var cancellables = Set<AnyCancellable>()

    /// Graph is rate limited and the phantom class of bug is measured in days, not
    /// seconds — every 5 minutes is ample and keeps us far from any throttling.
    private static let runInterval: TimeInterval = 5 * 60

    func attach(config: GraphVerifierConfig,
                calendarManager: CalendarManager,
                graphProvider: GraphCalendarProvider,
                diagnosticLog: DiagnosticLog) {
        self.config = config
        self.calendarManager = calendarManager
        self.graphProvider = graphProvider
        self.diagnosticLog = diagnosticLog

        // Ride the poll via the published event list rather than `onPollComplete`, which
        // the mirror engine already owns (a single closure — assigning it here would
        // silently disable mirroring). `verifyIfDue` throttles to `runInterval`.
        calendarManager.$upcomingWeek
            .sink { [weak self] _ in self?.verifyIfDue() }
            .store(in: &cancellables)
    }

    /// True when this event should not fire reminders because the server disagrees with
    /// macOS. Wired into `CalendarManager.upstreamGate`.
    func suppresses(_ meeting: MeetingEvent) -> Bool {
        guard config?.isEnabled == true else { return false }
        return verdicts[meeting.id]?.suppressesReminders == true
    }

    func verdict(for meeting: MeetingEvent) -> Verdict? {
        guard config?.isEnabled == true else { return nil }
        return verdicts[meeting.id]
    }

    /// Called after each poll; runs at most every `runInterval`.
    func verifyIfDue() {
        guard config?.isEnabled == true else {
            if !verdicts.isEmpty { verdicts.removeAll(); provisional.removeAll() }
            return
        }
        if let lastRun, Date().timeIntervalSince(lastRun) < Self.runInterval { return }
        Task { await verify() }
    }

    func verify() async {
        guard let config, config.isEnabled,
              let calendarManager, let graphProvider else { return }
        guard graphProvider.isAuthorized else {
            lastError = "Not signed in to Microsoft 365."
            return
        }

        let candidates = calendarManager.upcomingWeek.filter {
            $0.isExchangeBacked && !$0.isAllDay && !$0.isCancelled
        }
        guard !candidates.isEmpty else { lastRun = Date(); return }

        let window = max(3600, (candidates.map(\.startDate).max() ?? Date()).timeIntervalSinceNow + 3600)
        let serverEvents: [MeetingEvent]
        do {
            serverEvents = try await graphProvider.fetchUpcomingEvents(within: window)
        } catch {
            // Abort — a failed fetch must never read as "the server has nothing".
            lastError = error.localizedDescription
            diagnosticLog?.warn(.calendar, "Graph verification skipped — fetch failed: \(error.localizedDescription)")
            return
        }
        guard !serverEvents.isEmpty else {
            lastError = "Microsoft 365 returned no events; skipping verification."
            diagnosticLog?.warn(.calendar, "Graph verification skipped — server returned 0 events (treating as unreliable, not as 'all cancelled')")
            return
        }

        // Graph and EventKit ids are unrelated, so match on what both agree about:
        // normalised title plus start minute.
        var server: [String: Bool] = [:]   // key → isCancelled
        for event in serverEvents {
            server[Self.matchKey(title: event.title, start: event.startDate)] = event.isCancelled
        }

        var fresh: [String: Verdict] = [:]
        for meeting in candidates {
            let key = Self.matchKey(title: meeting.title, start: meeting.startDate)
            if let cancelled = server[key] {
                fresh[meeting.id] = cancelled ? .cancelledUpstream : .confirmed
            } else {
                fresh[meeting.id] = .absentUpstream
            }
        }

        // Two-run rule for suppressing verdicts; confirmations apply at once.
        var promoted: [String: Verdict] = [:]
        for (id, verdict) in fresh {
            if verdict == .confirmed {
                promoted[id] = .confirmed
            } else if provisional[id] == verdict {
                promoted[id] = verdict
                if verdicts[id] != verdict, let title = candidates.first(where: { $0.id == id })?.title {
                    diagnosticLog?.warn(.calendar, "Graph verification: \"\(title)\" \(verdict.shortReason) — reminders suppressed")
                }
            }
        }
        provisional = fresh
        verdicts = promoted
        lastRun = Date()
        lastError = nil

        let flagged = promoted.values.filter { $0.suppressesReminders }.count
        diagnosticLog?.info(.calendar, "Graph verification: \(candidates.count) Exchange event(s) checked against \(serverEvents.count) server event(s), \(flagged) flagged")
    }

    /// Normalised title + start minute. Titles are compared case-insensitively with
    /// whitespace collapsed and any "Canceled:"/"Cancelled:" prefix stripped, because one
    /// side often carries it and the other doesn't.
    private static func matchKey(title: String, start: Date) -> String {
        var normalized = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["canceled:", "cancelled:"] where normalized.hasPrefix(prefix) {
            normalized = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        normalized = normalized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(normalized)\u{1F}\(Int(start.timeIntervalSince1970 / 60))"
    }
}

/// Settings for the verifier. Off by default: it needs a Microsoft 365 sign-in, and
/// signing in is a decision, not a default.
@MainActor
final class GraphVerifierConfig: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "graphVerifierEnabled") }
    }

    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "graphVerifierEnabled") as? Bool ?? false
    }
}
