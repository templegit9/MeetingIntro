import Combine
import Foundation

/// Settings for the Quick Add text-to-calendar feature.
///
/// The OpenRouter API key is a credential → Keychain via `KeychainStore`
/// (same pattern as the Graph OAuth token). Everything else is UserDefaults.
@MainActor
final class QuickAddConfig: ObservableObject {

    /// OpenRouter API key. Empty string = no key = on-device parsing only.
    @Published var openRouterKey: String {
        didSet {
            if openRouterKey.isEmpty {
                KeychainStore.delete(Self.keychainAccount)
            } else {
                KeychainStore.set(openRouterKey, for: Self.keychainAccount)
            }
        }
    }

    /// OpenRouter model identifier. Any OpenAI-compatible chat model works.
    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.k_modelID) }
    }

    /// Calendar identifier for created events. nil → EventKit's default calendar.
    @Published var defaultCalendarID: String? {
        didSet { UserDefaults.standard.set(defaultCalendarID, forKey: Self.k_defaultCalendarID) }
    }

    /// Duration applied when the parsed text has a start but no end time.
    @Published var defaultDurationMinutes: Int {
        didSet { UserDefaults.standard.set(defaultDurationMinutes, forKey: Self.k_defaultDuration) }
    }

    var hasLLMKey: Bool { !openRouterKey.isEmpty }

    init() {
        let d = UserDefaults.standard
        self.openRouterKey = KeychainStore.get(Self.keychainAccount) ?? ""
        self.modelID = d.string(forKey: Self.k_modelID) ?? "anthropic/claude-haiku-4.5"
        self.defaultCalendarID = d.string(forKey: Self.k_defaultCalendarID)
        let stored = d.integer(forKey: Self.k_defaultDuration)
        self.defaultDurationMinutes = stored > 0 ? stored : 30
    }

    private static let keychainAccount = "openRouterKey"
    private static let k_modelID = "quickAdd_modelID"
    private static let k_defaultCalendarID = "quickAdd_defaultCalendarID"
    private static let k_defaultDuration = "quickAdd_defaultDurationMinutes"
}
