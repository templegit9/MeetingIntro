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
