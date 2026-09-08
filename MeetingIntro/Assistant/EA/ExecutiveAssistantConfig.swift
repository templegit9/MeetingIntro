import Foundation

/// Settings for the Executive Assistant plugin. Off by default, like every plugin.
///
/// Separate from `AssistantConfig` (File Organizer) and `QuickAddConfig` on purpose: this
/// one always points at a **local** Ollama, because the whole premise is that nothing you
/// say to it leaves the Mac. No API key lives here — there is nothing to authenticate to.
@MainActor
final class ExecutiveAssistantConfig: ObservableObject {

    static let enabledKey = "executiveAssistantEnabled"
    static let defaultBaseURL = "http://127.0.0.1:11434"
    /// Measured on the fixture set: 12/12 tool choices correct, 5.9s median, 12.7s
    /// slowest — roughly twice as fast as gemma4:e4b for the same accuracy. Both work;
    /// this is the better default.
    static let defaultModel = "gpt-oss:20b"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "ea_baseURL") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "ea_model") }
    }
    /// Seconds to wait for a reply. A local model on a cold start can take the better
    /// part of a minute for the first token; failing at 20s would look like a bug.
    @Published var timeoutSeconds: Int {
        didSet { UserDefaults.standard.set(timeoutSeconds, forKey: "ea_timeout") }
    }
    /// Which calendar new events land in. nil = the app's default write target.
    @Published var calendarID: String? {
        didSet { UserDefaults.standard.set(calendarID, forKey: "ea_calendarID") }
    }

    init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Self.enabledKey)
        baseURL = d.string(forKey: "ea_baseURL") ?? Self.defaultBaseURL
        model = d.string(forKey: "ea_model") ?? Self.defaultModel
        timeoutSeconds = d.object(forKey: "ea_timeout") as? Int ?? 120
        calendarID = d.string(forKey: "ea_calendarID")
    }
}
