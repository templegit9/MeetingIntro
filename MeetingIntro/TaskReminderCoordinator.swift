import AppKit
import Combine
import Foundation

/// Fires a task's deadline reminder through the user-selected channels (Issue #19).
/// Isolated from `CalendarManager` (tasks aren't `MeetingEvent`s, and `onPollComplete`
/// is already taken by the mirror engine): runs its own 30s timer plus an immediate
/// evaluation on wake. Fire-once is enforced by a persisted key set so a reminder isn't
/// re-sent after relaunch.
@MainActor
final class TaskReminderCoordinator: ObservableObject {

    private weak var taskManager: TaskManager?
    private weak var notificationManager: NotificationManager?
    private weak var voiceReminder: VoiceReminderManager?
    private weak var overlayController: OverlayWindowController?
    private var diagnosticLog: DiagnosticLog?

    private var timer: Timer?
    private var firedKeys: Set<String> = []
    /// Tasks snoozed until a future time — re-fire when reached.
    private var snoozedUntil: [String: Date] = [:]
    private static let k_fired = "tasks_firedReminderKeys"

    init() {
        firedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.k_fired) ?? [])
    }

    func attach(taskManager: TaskManager,
                notificationManager: NotificationManager,
                voiceReminder: VoiceReminderManager,
                overlayController: OverlayWindowController,
                diagnosticLog: DiagnosticLog) {
        self.taskManager = taskManager
        self.notificationManager = notificationManager
        self.voiceReminder = voiceReminder
        self.overlayController = overlayController
        self.diagnosticLog = diagnosticLog

        // Evaluate on wake immediately (the 30s timer is suspended during sleep).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.evaluate() } }

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        evaluate()
    }

    /// Re-remind about a task after `minutes` (from the notification/overlay Snooze).
    func snooze(taskID: String, minutes: Int) {
        snoozedUntil[taskID] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        overlayController?.dismissTaskDeadline()
    }

    private func evaluate() {
        guard let taskManager else { return }
        let now = Date()
        var didFire = false
        for task in taskManager.tasks where !task.isCompleted {
            // Snoozed → fire again once the snooze elapses.
            if let until = snoozedUntil[task.id] {
                if now >= until { snoozedUntil[task.id] = nil; fire(task) }
                continue
            }
            guard let remindAt = task.remindAt, let dueDate = task.dueDate else { continue }
            guard now >= remindAt else { continue }
            let key = "\(task.id)_\(Int(dueDate.timeIntervalSince1970))"
            guard !firedKeys.contains(key) else { continue }
            firedKeys.insert(key)
            didFire = true
            fire(task)
        }
        // Prune keys for tasks that no longer exist.
        let liveKeys = Set(taskManager.tasks.compactMap { t -> String? in
            guard let due = t.dueDate else { return nil }
            return "\(t.id)_\(Int(due.timeIntervalSince1970))"
        })
        let pruned = firedKeys.intersection(liveKeys)
        if pruned != firedKeys { firedKeys = pruned; didFire = true }
        if didFire { persist() }
    }

    private func fire(_ task: TaskItem) {
        diagnosticLog?.info(.reminder, "Task due reminder — \"\(task.title)\" — notify=\(task.sendNotification) voice=\(task.playVoice) overlay=\(task.showOverlay)")
        if task.sendNotification { notificationManager?.sendTaskDueNotification(for: task) }
        if task.playVoice { voiceReminder?.speak(phrase: "Task due: \(task.title)") }
        if task.showOverlay { overlayController?.showTaskDeadline(for: task) }
    }

    private func persist() {
        UserDefaults.standard.set(Array(firedKeys), forKey: Self.k_fired)
    }
}
