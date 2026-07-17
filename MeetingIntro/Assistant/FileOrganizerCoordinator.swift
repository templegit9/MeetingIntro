import Combine
import Foundation
import AppKit

/// Drives the Executive Assistant's automated triggers (Issue #17, Phase 2): a 30s timer +
/// wake observer for **scheduled** jobs, and a per-job `DirectoryWatcher` for **watched**
/// folders. A fired run either auto-applies (job.autoApply — with an undo + summary
/// notification) or publishes `pendingReview` (+ a heads-up notification) so the window
/// opens the dry-run preview. Manual "Organize now" is unchanged (still in the window).
@MainActor
final class FileOrganizerCoordinator: ObservableObject {

    /// A scheduled/watch run that needs the user to review before applying.
    struct PendingReview {
        let jobID: UUID
        let jobName: String
        var proposals: [FileProposal]
    }

    @Published var pendingReview: PendingReview?

    private weak var config: AssistantConfig?
    private weak var organizer: FileOrganizer?
    private weak var notificationManager: NotificationManager?
    var diagnosticLog: DiagnosticLog?

    private var timer: Timer?
    private var watchers: [UUID: DirectoryWatcher] = [:]
    private var running: Set<UUID> = []
    private var cancellables = Set<AnyCancellable>()

    func attach(config: AssistantConfig, organizer: FileOrganizer,
                notificationManager: NotificationManager, diagnosticLog: DiagnosticLog) {
        self.config = config
        self.organizer = organizer
        self.notificationManager = notificationManager
        self.diagnosticLog = diagnosticLog

        // Rebuild folder watchers whenever the job list changes (added/removed/toggled).
        config.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] jobs in self?.rebuildWatchers(jobs) }
            .store(in: &cancellables)

        // Scheduled runs: the 30s timer is suspended during sleep, so also evaluate on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.tick() } }

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        rebuildWatchers(config.jobs)
        tick()
    }

    // MARK: - Scheduled

    private func tick() {
        guard let config else { return }
        let now = Date()
        for job in config.jobs where job.scheduleEnabled {
            let interval = TimeInterval(max(1, job.scheduleIntervalHours) * 3600)
            let due = (job.lastRunAt ?? .distantPast).addingTimeInterval(interval)
            if now >= due { runJob(job, reason: "scheduled") }
        }
    }

    // MARK: - Folder watch

    private func rebuildWatchers(_ jobs: [OrganizeJob]) {
        let watched = Set(jobs.filter { $0.watchEnabled }.map { $0.id })
        // Drop watchers for jobs no longer watched / removed.
        for (id, w) in watchers where !watched.contains(id) { w.stop(); watchers[id] = nil }
        // Add watchers for newly watched jobs.
        for job in jobs where job.watchEnabled && watchers[job.id] == nil {
            guard let organizer, let url = organizer.resolveSource(job) else { continue }
            let id = job.id
            let watcher = DirectoryWatcher(url: url) { [weak self] in
                Task { @MainActor in
                    guard let self, let fresh = self.config?.jobs.first(where: { $0.id == id }) else { return }
                    self.runJob(fresh, reason: "new files")
                }
            }
            // The fd is open now; release the security scope (resolveSource started it).
            url.stopAccessingSecurityScopedResource()
            if let watcher { watchers[id] = watcher }
        }
    }

    // MARK: - Run

    private func runJob(_ job: OrganizeJob, reason: String) {
        guard !running.contains(job.id), let organizer else { return }
        running.insert(job.id)
        config?.markRun(job.id)   // stamp now so a scheduled job doesn't re-fire while it runs
        Task {
            defer { running.remove(job.id) }
            let proposals = await organizer.plan(job)
            guard !proposals.isEmpty else {
                diagnosticLog?.info(.assistant, "Auto-run \"\(job.name)\" (\(reason)): nothing to organize")
                return
            }
            if job.autoApply {
                let n = organizer.apply(proposals, job: job)?.moves.count ?? 0
                if n > 0 { notificationManager?.sendAssistantOrganizedNotification(folder: displayName(job), count: n) }
                diagnosticLog?.info(.assistant, "Auto-organized \"\(job.name)\" (\(reason)): \(n) files")
            } else {
                pendingReview = PendingReview(jobID: job.id, jobName: job.name, proposals: proposals)
                notificationManager?.sendAssistantReviewNotification(folder: displayName(job), count: proposals.count)
                diagnosticLog?.info(.assistant, "Auto-run \"\(job.name)\" (\(reason)): \(proposals.count) files ready to review")
            }
        }
    }

    private func displayName(_ job: OrganizeJob) -> String { job.name.isEmpty ? "the folder" : job.name }
}
