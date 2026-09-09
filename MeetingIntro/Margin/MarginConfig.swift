import Foundation

/// Settings for **Margin** — the notebook assistant. Off by default, like every plugin.
///
/// Margin is its own brand and its own namespace: nothing here reaches into MeetingIntro's
/// look or its settings, and every capability it has arrives through the tool registry.
/// That boundary is deliberate — it is what lets Margin become its own product without
/// unpicking the host app.
///
/// Separate from `AssistantConfig` (File Organizer) and `QuickAddConfig` on purpose: this
/// one always points at a **local** Ollama, because the whole premise is that nothing you
/// say to it leaves the Mac. No API key lives here — there is nothing to authenticate to.
@MainActor
final class MarginConfig: ObservableObject {

    static let enabledKey = "marginEnabled"
    static let defaultBaseURL = "http://127.0.0.1:11434"
    /// Measured on the fixture set: 12/12 tool choices correct, 5.9s median, 12.7s
    /// slowest — roughly twice as fast as gemma4:e4b for the same accuracy. Both work;
    /// this is the better default.
    static let defaultModel = "gpt-oss:20b"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "margin_baseURL") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "margin_model") }
    }
    /// Seconds to wait for a reply. A local model on a cold start can take the better
    /// part of a minute for the first token; failing at 20s would look like a bug.
    @Published var timeoutSeconds: Int {
        didSet { UserDefaults.standard.set(timeoutSeconds, forKey: "margin_timeout") }
    }
    /// Which calendar new events land in. nil = the app's default write target.
    @Published var calendarID: String? {
        didSet { UserDefaults.standard.set(calendarID, forKey: "margin_calendarID") }
    }
    /// ⌥Space summons it. A real system hotkey, so no Accessibility prompt and no
    /// misfires while typing — the reason the Space+N chord was not built.
    @Published var summonShortcutEnabled: Bool {
        didSet { UserDefaults.standard.set(summonShortcutEnabled, forKey: "margin_summon") }
    }
    /// The cover sits on screen at this opacity until the pointer nears it.
    @Published var restingOpacity: Double {
        didSet { UserDefaults.standard.set(restingOpacity, forKey: "margin_restingOpacity") }
    }
    /// Folded corners per day. The spec's budget: three, then everything else waits on
    /// the ribbon. A nudge system without a hard cap becomes Clippy.
    @Published var foldedCornerBudget: Int {
        didSet { UserDefaults.standard.set(foldedCornerBudget, forKey: "margin_foldBudget") }
    }
    /// The elastic band: it still opens on ⌥Space, it just won't speak first.
    @Published var banded: Bool {
        didSet { UserDefaults.standard.set(banded, forKey: "margin_banded") }
    }

    init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Self.enabledKey)
        baseURL = d.string(forKey: "margin_baseURL") ?? Self.defaultBaseURL
        model = d.string(forKey: "margin_model") ?? Self.defaultModel
        timeoutSeconds = d.object(forKey: "margin_timeout") as? Int ?? 120
        calendarID = d.string(forKey: "margin_calendarID")
        summonShortcutEnabled = d.object(forKey: "margin_summon") as? Bool ?? true
        restingOpacity = d.object(forKey: "margin_restingOpacity") as? Double ?? 0.30
        foldedCornerBudget = d.object(forKey: "margin_foldBudget") as? Int ?? 3
        banded = d.bool(forKey: "margin_banded")
    }
}
