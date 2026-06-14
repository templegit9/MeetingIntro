import Foundation

/// Configures a single countdown trigger with notification preferences.
/// Each countdown minute can independently enable overlay, system notification, and voice.
struct CountdownTrigger: Codable, Identifiable, Equatable {
    let minutes: Int
    var showOverlay: Bool
    var sendNotification: Bool
    var playVoice: Bool

    var id: Int { minutes }

    var label: String {
        minutes == 1 ? "1 minute before" : "\(minutes) minutes before"
    }
}

/// Manages the list of configured countdown triggers, persisted via UserDefaults.
@MainActor
final class CountdownConfigManager: ObservableObject {

    @Published var triggers: [CountdownTrigger] {
        didSet { save() }
    }

    /// When true and a join URL is detected for the meeting, the countdown overlay
    /// shows a prominent "Join Meeting" button.
    @Published var joinButtonEnabled: Bool {
        didSet { UserDefaults.standard.set(joinButtonEnabled, forKey: "joinButtonEnabled") }
    }

    /// When true (and a join URL is detected), the countdown overlay shows a
    /// "Start at Time" button that arms an automatic join: at the meeting's start
    /// time MeetingIntro opens the conference link for you (Issue #2).
    @Published var autoJoinEnabled: Bool {
        didSet { UserDefaults.standard.set(autoJoinEnabled, forKey: "autoJoinEnabled") }
    }

    /// Freshness bound (minutes) for an armed auto-join. The link is opened only if
    /// the start time is reached within this window; past it (e.g. the Mac slept
    /// through the start) the join is treated as missed rather than yanking you into
    /// a meeting that began long ago. See `CalendarManager.evaluateAutoJoin`.
    @Published var autoJoinGraceMinutes: Int {
        didSet { UserDefaults.standard.set(autoJoinGraceMinutes, forKey: "autoJoinGraceMinutes") }
    }

    /// Show a small, non-blocking heads-up overlay shortly before an armed meeting
    /// auto-joins. Default on.
    @Published var autoJoinImminentOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(autoJoinImminentOverlayEnabled, forKey: "autoJoinImminentOverlayEnabled") }
    }

    /// How many seconds before start the heads-up overlay appears (clamped 15–300).
    @Published var autoJoinOverlayLeadSeconds: Int {
        didSet { UserDefaults.standard.set(autoJoinOverlayLeadSeconds, forKey: "autoJoinOverlayLeadSeconds") }
    }

    static let availableMinutes = [1, 2, 3, 5, 10, 15]

    init() {
        if let data = UserDefaults.standard.data(forKey: "countdownTriggers"),
           let decoded = try? JSONDecoder().decode([CountdownTrigger].self, from: data) {
            self.triggers = decoded
        } else {
            // Default: 2 minutes with overlay only
            self.triggers = [
                CountdownTrigger(minutes: 2, showOverlay: true, sendNotification: false, playVoice: false)
            ]
        }
        if UserDefaults.standard.object(forKey: "joinButtonEnabled") == nil {
            self.joinButtonEnabled = true
        } else {
            self.joinButtonEnabled = UserDefaults.standard.bool(forKey: "joinButtonEnabled")
        }
        if UserDefaults.standard.object(forKey: "autoJoinEnabled") == nil {
            self.autoJoinEnabled = true
        } else {
            self.autoJoinEnabled = UserDefaults.standard.bool(forKey: "autoJoinEnabled")
        }
        let storedGrace = UserDefaults.standard.object(forKey: "autoJoinGraceMinutes") as? Int
        self.autoJoinGraceMinutes = storedGrace ?? 2
        self.autoJoinImminentOverlayEnabled = UserDefaults.standard.object(forKey: "autoJoinImminentOverlayEnabled") as? Bool ?? true
        self.autoJoinOverlayLeadSeconds = UserDefaults.standard.object(forKey: "autoJoinOverlayLeadSeconds") as? Int ?? 60
    }

    /// Get all enabled minutes (for CalendarManager compatibility).
    var enabledMinutes: [Int] {
        triggers.map(\.minutes).sorted(by: >)
    }

    /// Check if a specific minute is configured.
    func trigger(for minutes: Int) -> CountdownTrigger? {
        triggers.first { $0.minutes == minutes }
    }

    /// Add a new countdown minute with defaults.
    func addTrigger(minutes: Int) {
        guard !triggers.contains(where: { $0.minutes == minutes }) else { return }
        triggers.append(CountdownTrigger(minutes: minutes, showOverlay: true, sendNotification: false, playVoice: false))
        triggers.sort { $0.minutes < $1.minutes }
    }

    /// Remove a countdown trigger.
    func removeTrigger(minutes: Int) {
        triggers.removeAll { $0.minutes == minutes }
    }

    /// Update a specific trigger's notification preferences.
    func update(_ updated: CountdownTrigger) {
        if let idx = triggers.firstIndex(where: { $0.minutes == updated.minutes }) {
            triggers[idx] = updated
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(triggers) {
            UserDefaults.standard.set(data, forKey: "countdownTriggers")
        }
    }
}
