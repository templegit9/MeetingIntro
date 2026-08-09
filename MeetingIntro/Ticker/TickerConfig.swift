import Foundation

/// Settings for the Ticker plugin — the news-chyron strip that crawls across the top of
/// the screen. Third opt-in plugin (after File Organizer and Dictionary): **off by
/// default**, and when off nothing about the reminder/meeting core changes.
///
/// Every tunable lives here (persisted to UserDefaults on `didSet`, the QuickAddConfig
/// pattern) — no magic numbers in the window controller or the view.
@MainActor
final class TickerConfig: ObservableObject {

    /// Master switch. Bound directly by the Plugins tab card, so toggling it live
    /// shows/hides the strip via `TickerCoordinator`.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "tickerEnabled") }
    }

    // MARK: - Sources (what rides in the feed)

    /// Today's remaining meetings, with their countdown.
    @Published var showMeetings: Bool {
        didSet { UserDefaults.standard.set(showMeetings, forKey: "tickerShowMeetings") }
    }
    /// Incomplete tasks that are overdue or due within `taskLookaheadHours`.
    @Published var showTasks: Bool {
        didSet { UserDefaults.standard.set(showTasks, forKey: "tickerShowTasks") }
    }
    /// Cancelled meetings you haven't acknowledged yet.
    @Published var showCancellations: Bool {
        didSet { UserDefaults.standard.set(showCancellations, forKey: "tickerShowCancellations") }
    }
    /// App state worth knowing at a glance: recording in progress, auto-join armed.
    @Published var showStatus: Bool {
        didSet { UserDefaults.standard.set(showStatus, forKey: "tickerShowStatus") }
    }

    /// How far ahead a task's due date can be and still ride in the ticker.
    @Published var taskLookaheadHours: Int {
        didSet { UserDefaults.standard.set(taskLookaheadHours, forKey: "tickerTaskLookaheadHours") }
    }

    // MARK: - Presentation

    /// Crawl speed in points per second. 40 ≈ a TV news crawl.
    @Published var scrollSpeed: Double {
        didSet { UserDefaults.standard.set(scrollSpeed, forKey: "tickerScrollSpeed") }
    }

    /// Width of the strip in points. Kept narrow by default so it lives in the empty
    /// middle of the menu bar without reaching either app menus or status icons.
    @Published var width: Double {
        didSet { UserDefaults.standard.set(width, forKey: "tickerWidth") }
    }

    // MARK: - Auto-hide

    /// Hide while screen-sharing — a crawl of your task titles across a shared screen is
    /// a real leak, so this defaults on.
    @Published var hideWhileScreenSharing: Bool {
        didSet { UserDefaults.standard.set(hideWhileScreenSharing, forKey: "tickerHideWhileScreenSharing") }
    }
    /// Hide while the mic is in use (the same in-call signal that gates reminders).
    @Published var hideWhileInCall: Bool {
        didSet { UserDefaults.standard.set(hideWhileInCall, forKey: "tickerHideWhileInCall") }
    }
    /// Hide while a Focus mode is on.
    @Published var hideWhileFocus: Bool {
        didSet { UserDefaults.standard.set(hideWhileFocus, forKey: "tickerHideWhileFocus") }
    }

    /// Bounds the UI controls (and clamps anything hand-edited in defaults).
    static let speedRange: ClosedRange<Double> = 10...140
    static let widthRange: ClosedRange<Double> = 240...900

    init() {
        let d = UserDefaults.standard
        // Off by default — this is an opt-in plugin.
        self.isEnabled = d.object(forKey: "tickerEnabled") as? Bool ?? false
        self.showMeetings = d.object(forKey: "tickerShowMeetings") as? Bool ?? true
        self.showTasks = d.object(forKey: "tickerShowTasks") as? Bool ?? true
        self.showCancellations = d.object(forKey: "tickerShowCancellations") as? Bool ?? true
        self.showStatus = d.object(forKey: "tickerShowStatus") as? Bool ?? false
        self.taskLookaheadHours = d.object(forKey: "tickerTaskLookaheadHours") as? Int ?? 24
        self.scrollSpeed = d.object(forKey: "tickerScrollSpeed") as? Double ?? 40
        self.width = d.object(forKey: "tickerWidth") as? Double ?? 460
        self.hideWhileScreenSharing = d.object(forKey: "tickerHideWhileScreenSharing") as? Bool ?? true
        self.hideWhileInCall = d.object(forKey: "tickerHideWhileInCall") as? Bool ?? true
        self.hideWhileFocus = d.object(forKey: "tickerHideWhileFocus") as? Bool ?? true
    }

    /// True when no source is selected — the feed can't produce anything, so the
    /// Settings UI warns instead of leaving the user with a silently blank strip.
    var hasNoSources: Bool {
        !(showMeetings || showTasks || showCancellations || showStatus)
    }
}
