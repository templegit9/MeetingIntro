import Foundation

/// Durable execution receipts. A write in flight at interruption is uncertain, never retried automatically.
@MainActor final class MarginJobStore: ObservableObject {
    struct Step: Codable, Identifiable {
        var id = UUID()
        let title: String
        let tool: String
        let arguments: Data
        var destination: String? = nil
        var state = "pending"
        var result: String? = nil
    }
    struct Job: Codable, Identifiable {
        var id = UUID()
        let title: String
        var steps: [Step]
        var state = "awaiting confirmation"
        var updated = Date()
    }
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var problem: String?
    private let url: URL
    private var active: Set<UUID> = []
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingIntro/Margin/jobs.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: self.url))
                for j in jobs.indices {
                    for s in jobs[j].steps.indices where jobs[j].steps[s].state == "running" {
                        jobs[j].steps[s].state = "uncertain"
                        jobs[j].steps[s].result = "Interrupted during execution. Check the destination before making a new request."
                    }
                    if jobs[j].state == "running" { jobs[j].state = "paused after restart" }
                }
            }
        } catch { problem = "Job journal could not be read: \(error.localizedDescription)" }
    }
    func add(_ job: Job) throws {
        guard problem == nil else { throw ToolArgumentError(message: problem!) }
        guard active.isEmpty else { throw ToolArgumentError(message: "Wait for the current job to finish or pause it before preparing another.") }
        jobs.insert(job, at: 0)
        do { try persist() } catch { jobs.removeAll { $0.id == job.id }; throw error }
    }
    func pause(_ id: UUID) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { throw ToolArgumentError(message: "That job no longer exists.") }
        jobs[i].state = "paused"
        try persist()
    }
    /// Human reconciliation after inspecting the destination; never inferred from a transport error.
    func resolve(_ id: UUID, stepID: UUID, wasCreated: Bool) throws {
        guard !active.contains(id), let j = jobs.firstIndex(where: { $0.id == id }),
              let s = jobs[j].steps.firstIndex(where: { $0.id == stepID }), jobs[j].steps[s].state == "uncertain" else {
            throw ToolArgumentError(message: "Only an uncertain, inactive step can be reconciled.")
        }
        jobs[j].steps[s].state = wasCreated ? "completed" : "pending"
        jobs[j].steps[s].result = wasCreated ? "You checked the destination: already created." : "You checked the destination: not created. Awaiting a fresh preview."
        jobs[j].state = jobs[j].steps.allSatisfy { $0.state == "completed" } ? "completed" : "paused"; try persist()
    }

    func run(_ id: UUID, selected: Set<UUID>, execute: (Step) async throws -> String) async throws -> String {
        guard !active.contains(id), let j = jobs.firstIndex(where: { $0.id == id }) else {
            throw ToolArgumentError(message: "This job is already running or no longer exists.")
        }
        guard problem == nil else { throw ToolArgumentError(message: problem!) }
        active.insert(id); defer { active.remove(id) }
        jobs[j].state = "running"; try persist()
        for s in jobs[j].steps.indices {
            if jobs[j].state == "paused" || Task.isCancelled { break }
            guard selected.contains(jobs[j].steps[s].id), jobs[j].steps[s].state == "pending" else { continue }
            let step = jobs[j].steps[s]
            let duplicate = jobs.contains { other in
                other.steps.contains { $0.id != step.id && $0.tool == step.tool && $0.arguments == step.arguments && ["completed", "running", "uncertain"].contains($0.state) }
            }
            if duplicate {
                jobs[j].steps[s].state = "held duplicate"
                jobs[j].steps[s].result = "An identical step was already completed or has an uncertain result. Check the destination; no repeat was attempted."
                jobs[j].state = "needs review"; try persist(); break
            }
            jobs[j].steps[s].state = "running"; try persist() // persisted boundary before external effect
            do {
                let result = try await execute(jobs[j].steps[s])
                jobs[j].steps[s].state = "completed"; jobs[j].steps[s].result = result
                try persist()
            } catch {
                // Provider errors can arrive after a remote write succeeded. Never assume retry-safe.
                jobs[j].steps[s].state = "uncertain"
                jobs[j].steps[s].result = error.localizedDescription
                jobs[j].state = "needs review"
                try persist()
                break
            }
        }
        if jobs[j].state == "running" { jobs[j].state = jobs[j].steps.allSatisfy { $0.state == "completed" } ? "completed" : "paused" }
        try persist()
        return jobs[j].steps.map { "\($0.title): \($0.result ?? $0.state)" }.joined(separator: "\n")
    }
    private func persist() throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
        } catch { problem = "Cannot save job progress: \(error.localizedDescription)"; throw error }
    }
}
