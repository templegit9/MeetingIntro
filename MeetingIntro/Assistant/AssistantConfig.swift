import Foundation

/// Config for the Executive Assistant plugin (Issue #17): its OWN LLM provider/key/model
/// (separate from Quick Add + transcription), the saved folders, and the undo history.
/// Persistence mirrors `QuickAddConfig` (Keychain for the key, UserDefaults JSON for lists).
@MainActor
final class AssistantConfig: ObservableObject {

    /// LLM provider preset (reuses the Quick Add provider enum).
    @Published var provider: QuickAddProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.k_provider)
            // Switching to a preset fills its endpoint + suggested model; custom keeps the user's.
            if provider != .custom {
                if let base = provider.baseURL { apiBaseURL = base }
                modelID = provider.suggestedModel
            }
        }
    }
    @Published var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: Self.k_baseURL) }
    }
    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: Self.k_model) }
    }
    /// API key — Keychain-backed. Empty for local/keyless providers (Ollama).
    @Published var key: String {
        didSet {
            if key.isEmpty { KeychainStore.delete(Self.keychainAccount) }
            else { KeychainStore.set(key, for: Self.keychainAccount) }
        }
    }
    @Published var jobs: [OrganizeJob] {
        didSet { Self.persist(jobs, key: Self.k_jobs) }
    }
    /// User-defined organize rules (deterministic, applied before the model).
    @Published var rules: [OrganizeRule] {
        didSet { Self.persist(rules, key: Self.k_rules) }
    }
    /// Free-text organizing preferences fed into every model run (v2.14.0).
    @Published var instructions: String {
        didSet { UserDefaults.standard.set(instructions, forKey: Self.k_instructions) }
    }
    /// Circuit-breaker: an automated auto-apply run larger than this routes to review instead.
    @Published var autoApplyMaxFiles: Int {
        didSet { UserDefaults.standard.set(autoApplyMaxFiles, forKey: Self.k_autoCap) }
    }
    /// Recent applied runs, newest last — for revert-after-the-fact. Bounded to 10.
    @Published var undoBatches: [UndoBatch] {
        didSet { Self.persist(undoBatches, key: Self.k_undo) }
    }

    var hasKey: Bool { !key.isEmpty }
    /// Ready to call the model when a key is set, or the provider needs none (Ollama/custom).
    var llmReady: Bool { hasKey || !provider.needsKey }

    init() {
        let d = UserDefaults.standard
        self.provider = QuickAddProvider(rawValue: d.string(forKey: Self.k_provider) ?? "") ?? .openRouter
        self.apiBaseURL = d.string(forKey: Self.k_baseURL) ?? (QuickAddProvider.openRouter.baseURL ?? QuickAddConfig.defaultBaseURL)
        self.modelID = d.string(forKey: Self.k_model) ?? "anthropic/claude-haiku-4.5"
        self.key = KeychainStore.get(Self.keychainAccount) ?? ""
        self.jobs = Self.load([OrganizeJob].self, key: Self.k_jobs) ?? []
        self.rules = Self.load([OrganizeRule].self, key: Self.k_rules) ?? []
        self.instructions = d.string(forKey: Self.k_instructions) ?? ""
        let cap = d.integer(forKey: Self.k_autoCap)
        self.autoApplyMaxFiles = cap > 0 ? cap : 50
        self.undoBatches = Self.load([UndoBatch].self, key: Self.k_undo) ?? []
    }

    // MARK: - Jobs CRUD
    func addJob(_ job: OrganizeJob) { jobs.append(job) }
    func updateJob(_ job: OrganizeJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job }
    }
    func removeJob(_ id: UUID) { jobs.removeAll { $0.id == id } }
    /// Stamp a job's last automated-run time (drives the scheduled cadence).
    func markRun(_ id: UUID, at date: Date = Date()) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].lastRunAt = date }
    }

    // MARK: - Rules CRUD
    func addRule(_ rule: OrganizeRule) { rules.append(rule) }
    func updateRule(_ rule: OrganizeRule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) { rules[i] = rule }
    }
    func removeRule(_ id: UUID) { rules.removeAll { $0.id == id } }

    // MARK: - Undo history
    func recordUndo(_ batch: UndoBatch) {
        undoBatches.append(batch)
        if undoBatches.count > 10 { undoBatches.removeFirst(undoBatches.count - 10) }
    }
    func removeUndo(_ id: UUID) { undoBatches.removeAll { $0.id == id } }

    // MARK: - Persistence helpers
    private static func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let keychainAccount = "assistantLLMKey"
    private static let k_provider = "assistant_provider"
    private static let k_baseURL = "assistant_baseURL"
    private static let k_model = "assistant_model"
    private static let k_jobs = "assistant_jobs"
    private static let k_rules = "assistant_rules"
    private static let k_instructions = "assistant_instructions"
    private static let k_autoCap = "assistant_autoApplyMaxFiles"
    private static let k_undo = "assistant_undoBatches"
}
