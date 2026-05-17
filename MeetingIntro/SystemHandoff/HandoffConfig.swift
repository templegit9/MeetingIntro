import Combine
import Foundation
import Intents

/// User-controllable settings for the meeting handoff flow. Each toggle and device
/// preference is persisted to UserDefaults individually.
@MainActor
final class HandoffConfigManager: ObservableObject {

    /// Master toggles. When off, the coordinator does nothing for that subsystem.
    @Published var audioHandoffEnabled: Bool {
        didSet { UserDefaults.standard.set(audioHandoffEnabled, forKey: Self.k_audioEnabled) }
    }
    @Published var focusHandoffEnabled: Bool {
        didSet { UserDefaults.standard.set(focusHandoffEnabled, forKey: Self.k_focusEnabled) }
    }
    @Published var restoreOnEnd: Bool {
        didSet { UserDefaults.standard.set(restoreOnEnd, forKey: Self.k_restoreOnEnd) }
    }

    /// UIDs (stable across app restarts) of the user's preferred and fallback output devices.
    @Published var preferredOutputUID: String? {
        didSet { UserDefaults.standard.set(preferredOutputUID, forKey: Self.k_preferredUID) }
    }
    @Published var fallbackOutputUID: String? {
        didSet { UserDefaults.standard.set(fallbackOutputUID, forKey: Self.k_fallbackUID) }
    }

    init() {
        let d = UserDefaults.standard
        self.audioHandoffEnabled = d.object(forKey: Self.k_audioEnabled) as? Bool ?? false
        self.focusHandoffEnabled = d.object(forKey: Self.k_focusEnabled) as? Bool ?? false
        self.restoreOnEnd = d.object(forKey: Self.k_restoreOnEnd) as? Bool ?? true
        self.preferredOutputUID = d.string(forKey: Self.k_preferredUID)
        self.fallbackOutputUID = d.string(forKey: Self.k_fallbackUID)
    }

    private static let k_audioEnabled = "handoff_audioEnabled"
    private static let k_focusEnabled = "handoff_focusEnabled"
    private static let k_restoreOnEnd = "handoff_restoreOnEnd"
    private static let k_preferredUID = "handoff_preferredUID"
    private static let k_fallbackUID = "handoff_fallbackUID"
}
