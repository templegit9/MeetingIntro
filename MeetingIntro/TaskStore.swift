import Combine
import Foundation

/// Where tasks are stored. Phase 1 ships `.inApp`; `.appleReminders` (EventKit `EKReminder`)
/// is Phase 2 and needs the reminders entitlement + permission.
enum TaskStorageMode: String, Codable, CaseIterable, Identifiable {
    case inApp, appleReminders
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inApp:          return "In-app only"
        case .appleReminders: return "Apple Reminders"
        }
    }
}

/// User defaults + storage choice for the Tasks feature. Persisted to UserDefaults.
@MainActor
final class TaskConfig: ObservableObject {
    @Published var storageMode: TaskStorageMode {
        didSet { UserDefaults.standard.set(storageMode.rawValue, forKey: Self.k_mode) }
    }
    /// Default minutes-before-due to remind for a newly created task.
    @Published var defaultRemindLeadMinutes: Int {
        didSet { UserDefaults.standard.set(defaultRemindLeadMinutes, forKey: Self.k_lead) }
    }
    @Published var defaultShowOverlay: Bool {
        didSet { UserDefaults.standard.set(defaultShowOverlay, forKey: Self.k_overlay) }
    }
    @Published var defaultSendNotification: Bool {
        didSet { UserDefaults.standard.set(defaultSendNotification, forKey: Self.k_notify) }
    }
    @Published var defaultPlayVoice: Bool {
        didSet { UserDefaults.standard.set(defaultPlayVoice, forKey: Self.k_voice) }
    }

    init() {
        let d = UserDefaults.standard
        self.storageMode = TaskStorageMode(rawValue: d.string(forKey: Self.k_mode) ?? "") ?? .inApp
        self.defaultRemindLeadMinutes = d.object(forKey: Self.k_lead) as? Int ?? 0
        self.defaultShowOverlay = d.object(forKey: Self.k_overlay) as? Bool ?? false
        self.defaultSendNotification = d.object(forKey: Self.k_notify) as? Bool ?? true   // gentle default
        self.defaultPlayVoice = d.object(forKey: Self.k_voice) as? Bool ?? false
    }

    private static let k_mode = "tasks_storageMode"
    private static let k_lead = "tasks_defaultLead"
    private static let k_overlay = "tasks_defaultOverlay"
    private static let k_notify = "tasks_defaultNotify"
    private static let k_voice = "tasks_defaultVoice"
}

/// Owns the task list. Phase 1 persists to UserDefaults JSON (mirroring `QuickAddConfig`);
/// Phase 2 will route reads/writes to Apple Reminders when `config.storageMode` is
/// `.appleReminders` (the CRUD surface here is the seam for that).
@MainActor
final class TaskManager: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []

    private let config: TaskConfig
    private static let k_tasks = "tasks_items"

    init(config: TaskConfig) {
        self.config = config
        if let data = UserDefaults.standard.data(forKey: Self.k_tasks),
           let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) {
            self.tasks = decoded
        }
    }

    // MARK: - Derived lists

    /// Incomplete tasks sorted by due date (undated last), then completed tasks.
    var sorted: [TaskItem] {
        let active = tasks.filter { !$0.isCompleted }.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs.title < rhs.title
            }
        }
        let done = tasks.filter { $0.isCompleted }.sorted { ($0.dueDate ?? .distantPast) > ($1.dueDate ?? .distantPast) }
        return active + done
    }

    /// Incomplete tasks with a due time within the next `hours` (for the compact menu).
    func dueSoon(withinHours hours: Int = 24) -> [TaskItem] {
        let cutoff = Date().addingTimeInterval(TimeInterval(hours * 3600))
        return tasks
            .filter { !$0.isCompleted }
            .filter { if let d = $0.dueDate { return d <= cutoff } else { return false } }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    // MARK: - CRUD

    /// Build a task pre-filled with the user's default reminder settings.
    func makeTask(title: String, dueDate: Date?, notes: String? = nil) -> TaskItem {
        TaskItem(
            title: title,
            notes: notes,
            dueDate: dueDate,
            remindLeadMinutes: config.defaultRemindLeadMinutes,
            showOverlay: config.defaultShowOverlay,
            sendNotification: config.defaultSendNotification,
            playVoice: config.defaultPlayVoice
        )
    }

    func add(_ task: TaskItem) { tasks.append(task); persist() }

    func update(_ task: TaskItem) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task; persist() }
    }

    func toggleComplete(_ id: String) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].isCompleted.toggle(); persist() }
    }

    func complete(_ id: String) {
        if let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isCompleted {
            tasks[i].isCompleted = true; persist()
        }
    }

    func delete(_ id: String) { tasks.removeAll { $0.id == id }; persist() }

    func deleteCompleted() { tasks.removeAll { $0.isCompleted }; persist() }

    var hasCompleted: Bool { tasks.contains { $0.isCompleted } }
    var hasOverdue: Bool { tasks.contains { $0.isOverdue } }

    private func persist() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: Self.k_tasks)
        }
    }
}
