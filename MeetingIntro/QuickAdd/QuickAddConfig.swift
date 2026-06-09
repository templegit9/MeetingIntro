import Combine
import Foundation

/// Known OpenAI-compatible providers for the Quick Add parser. Each preset
/// carries its endpoint, a sensible default model, and whether a key is needed.
/// `custom` exposes the raw base-URL field for anything not listed.
enum QuickAddProvider: String, CaseIterable, Identifiable {
    case openRouter
    case groq
    case gemini
    case cerebras
    case ollama
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .groq:       return "Groq (free tier)"
        case .gemini:     return "Google Gemini (free tier)"
        case .cerebras:   return "Cerebras (free tier)"
        case .ollama:     return "Ollama (local, no key)"
        case .custom:     return "Custom endpoint…"
        }
    }

    /// nil for `.custom` — the user supplies the URL.
    var baseURL: String? {
        switch self {
        case .openRouter: return QuickAddConfig.defaultBaseURL
        case .groq:       return "https://api.groq.com/openai/v1"
        case .gemini:     return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .cerebras:   return "https://api.cerebras.ai/v1"
        case .ollama:     return "http://localhost:11434/v1"
        case .custom:     return nil
        }
    }

    var suggestedModel: String {
        switch self {
        case .openRouter: return "anthropic/claude-haiku-4.5"
        case .groq:       return "llama-3.3-70b-versatile"
        case .gemini:     return "gemini-2.0-flash-lite"
        case .cerebras:   return "llama-3.3-70b"
        case .ollama:     return "qwen3:4b"
        case .custom:     return ""
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openRouter: return "sk-or-…"
        case .groq:       return "gsk_…"
        case .gemini:     return "AIza…"
        case .cerebras:   return "csk-…"
        case .ollama, .custom: return "API key (optional)"
        }
    }

    var keyConsoleURL: String? {
        switch self {
        case .openRouter: return "https://openrouter.ai/keys"
        case .groq:       return "https://console.groq.com/keys"
        case .gemini:     return "https://aistudio.google.com/apikey"
        case .cerebras:   return "https://cloud.cerebras.ai"
        case .ollama, .custom: return nil
        }
    }

    var needsKey: Bool {
        switch self {
        case .ollama, .custom: return false
        default: return true
        }
    }

    /// Reverse-map a stored base URL to its preset; unrecognized → `.custom`.
    static func match(baseURL: String) -> QuickAddProvider {
        allCases.first { $0.baseURL == baseURL } ?? .custom
    }
}

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

    /// Base URL of any OpenAI-compatible chat-completions API. Defaults to
    /// OpenRouter; point it at Groq, Gemini, Cerebras, or a local Ollama
    /// (http://localhost:11434/v1) — the request shape is identical.
    @Published var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: Self.k_apiBaseURL) }
    }

    static let defaultBaseURL = "https://openrouter.ai/api/v1"

    /// Calendar identifier for created events. nil → EventKit's default calendar.
    @Published var defaultCalendarID: String? {
        didSet { UserDefaults.standard.set(defaultCalendarID, forKey: Self.k_defaultCalendarID) }
    }

    /// Duration applied when the parsed text has a start but no end time.
    @Published var defaultDurationMinutes: Int {
        didSet { UserDefaults.standard.set(defaultDurationMinutes, forKey: Self.k_defaultDuration) }
    }

    /// Saved meeting links the user can attach to created events. One may be marked
    /// `isDefault` — the one smart-attach uses for meeting-like phrases.
    @Published var meetingLinks: [SavedMeetingLink] {
        didSet { Self.persist(meetingLinks, key: Self.k_meetingLinks) }
    }

    /// Reusable `/trigger` templates (title + duration + link + location).
    @Published var templates: [QuickAddTemplate] {
        didSet { Self.persist(templates, key: Self.k_templates) }
    }

    var hasLLMKey: Bool { !openRouterKey.isEmpty }

    /// Smart parsing is usable when a key is set OR the base URL points somewhere
    /// custom (a local Ollama needs no key at all).
    var llmEnabled: Bool { hasLLMKey || apiBaseURL != Self.defaultBaseURL }

    /// The link smart-attach reaches for, or nil if none is marked default.
    var defaultLink: SavedMeetingLink? {
        meetingLinks.first(where: { $0.isDefault }) ?? meetingLinks.first
    }

    func link(id: UUID?) -> SavedMeetingLink? {
        guard let id else { return nil }
        return meetingLinks.first(where: { $0.id == id })
    }

    // MARK: - Link library CRUD

    func addLink(name: String, url: String) {
        let isFirst = meetingLinks.isEmpty
        meetingLinks.append(SavedMeetingLink(name: name, url: url, isDefault: isFirst))
    }

    func removeLink(_ id: UUID) {
        let wasDefault = meetingLinks.first(where: { $0.id == id })?.isDefault ?? false
        meetingLinks.removeAll { $0.id == id }
        // Keep a default if any links remain.
        if wasDefault, !meetingLinks.isEmpty, !meetingLinks.contains(where: { $0.isDefault }) {
            meetingLinks[0].isDefault = true
        }
        // A template pointing at the removed link falls back to no link.
        for i in templates.indices where templates[i].linkID == id {
            templates[i].linkID = nil
        }
    }

    func setDefaultLink(_ id: UUID) {
        for i in meetingLinks.indices {
            meetingLinks[i].isDefault = (meetingLinks[i].id == id)
        }
    }

    // MARK: - Template CRUD

    func addTemplate(_ template: QuickAddTemplate) { templates.append(template) }
    func removeTemplate(_ id: UUID) { templates.removeAll { $0.id == id } }
    func updateTemplate(_ template: QuickAddTemplate) {
        if let i = templates.firstIndex(where: { $0.id == template.id }) { templates[i] = template }
    }

    /// The preset matching the stored base URL (`.custom` when unrecognized).
    var provider: QuickAddProvider { .match(baseURL: apiBaseURL) }

    /// Switch provider preset: updates the endpoint and resets the model to the
    /// provider's suggested default (model IDs aren't portable across providers).
    /// Switching to `.custom` keeps the current URL for the user to edit.
    func setProvider(_ newProvider: QuickAddProvider) {
        if let url = newProvider.baseURL {
            apiBaseURL = url
            modelID = newProvider.suggestedModel
        }
        // .custom: leave URL + model as-is; the text fields take over.
    }

    init() {
        let d = UserDefaults.standard
        self.openRouterKey = KeychainStore.get(Self.keychainAccount) ?? ""
        self.modelID = d.string(forKey: Self.k_modelID) ?? "anthropic/claude-haiku-4.5"
        self.apiBaseURL = d.string(forKey: Self.k_apiBaseURL) ?? Self.defaultBaseURL
        self.defaultCalendarID = d.string(forKey: Self.k_defaultCalendarID)
        let stored = d.integer(forKey: Self.k_defaultDuration)
        self.defaultDurationMinutes = stored > 0 ? stored : 30
        self.meetingLinks = Self.load([SavedMeetingLink].self, key: Self.k_meetingLinks) ?? []
        self.templates = Self.load([QuickAddTemplate].self, key: Self.k_templates) ?? []
    }

    // MARK: - JSON persistence helpers

    private static func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let keychainAccount = "openRouterKey"
    private static let k_modelID = "quickAdd_modelID"
    private static let k_apiBaseURL = "quickAdd_apiBaseURL"
    private static let k_defaultCalendarID = "quickAdd_defaultCalendarID"
    private static let k_defaultDuration = "quickAdd_defaultDurationMinutes"
    private static let k_meetingLinks = "quickAdd_meetingLinks"
    private static let k_templates = "quickAdd_templates"
}
