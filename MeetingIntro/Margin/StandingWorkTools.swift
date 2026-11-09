import Foundation

struct ListJobsTool: AgentTool {
    let name = "list_jobs"
    let description = "List saved Margin jobs, their step results, and scheduled or watched folder jobs."
    let jobs: MarginJobStore
    let organizer: AssistantConfig?
    var parameters: [String: Any] { Self.schema([:]) }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        var lines = jobs.jobs.map { job in
            "\(job.title) · \(job.state)\nID: \(job.id.uuidString)\n" + job.steps.map { "\($0.title): \($0.state)\($0.result.map { " — " + $0 } ?? "")" }.joined(separator: "\n")
        }
        lines += (organizer?.jobs ?? []).map { job in
            "\(job.name) · \(job.watchEnabled ? "watching" : "watch off") · \(job.scheduleEnabled ? "scheduled" : "schedule off")\nID: \(job.id.uuidString)\n\(job.autoApply ? "Automatic apply enabled in File Organizer" : "Review required")\nLast run: \(job.lastRunAt?.formatted() ?? "Never")"
        }
        if let problem = jobs.problem { lines.insert(problem, at: 0) }
        return .answer("Jobs", lines.isEmpty ? ["No saved jobs."] : lines)
    }
}
struct PauseJobTool: AgentTool {
    let name = "pause_job"
    let description = "Pause a saved job by its exact ID from list_jobs. In-flight work finishes; no following step starts."
    let jobs: MarginJobStore
    let organizer: AssistantConfig?
    var parameters: [String: Any] { Self.schema(["id": Self.string("Exact job UUID from list_jobs")], required: ["id"]) }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        guard let raw = ToolArgs.string(a, "id"), let id = UUID(uuidString: raw) else { throw ToolArgumentError(message: "Use the job ID shown by list_jobs.") }
        if let job = jobs.jobs.first(where: { $0.id == id }) {
            return ProposedAction(kind: .change, title: "Pause \(job.title)", details: ["The current step may finish; following steps will wait."], confirmLabel: "Pause", run: { _ in try jobs.pause(id); return "Paused. Any in-flight step may still finish." })
        }
        guard let config = organizer, let job = config.jobs.first(where: { $0.id == id }) else { throw ToolArgumentError(message: "That job no longer exists.") }
        return ProposedAction(kind: .change, title: "Pause \(job.name)", details: ["Turn off its folder watch and schedule. A run already in progress may finish."], confirmLabel: "Pause", run: { _ in
            guard var fresh = config.jobs.first(where: { $0.id == id }) else { throw ToolArgumentError(message: "The job was removed.") }
            fresh.watchEnabled = false; fresh.scheduleEnabled = false; config.updateJob(fresh)
            return "Watch and schedule paused."
        })
    }
}
struct ResumeJobTool: AgentTool {
    let name = "resume_job"
    let description = "Prepare a fresh preview of pending calendar steps in a paused Margin job. Completed and uncertain steps are never replayed."
    let jobs: MarginJobStore
    let manager: CalendarManager
    let defaultMinutes: Int
    var parameters: [String: Any] { Self.schema(["id": Self.string("Exact job UUID from list_jobs")], required: ["id"]) }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        guard let id = ToolArgs.string(a, "id").flatMap(UUID.init(uuidString:)), let job = jobs.jobs.first(where: { $0.id == id }) else { throw ToolArgumentError(message: "Use an existing Margin job ID from list_jobs.") }
        let pending = job.steps.filter { $0.state == "pending" }
        guard !pending.isEmpty else { return .answer(job.title, ["No pending steps. Completed steps will not repeat. Check any uncertain result in the destination before making a new request."]) }
        var choices: [PageChoice] = []; var targets: Set<String> = []
        let calendars = await manager.writableCalendarsFromEnabledSources()
        for step in pending {
            guard step.tool == "create_event", let args = try JSONSerialization.jsonObject(with: step.arguments) as? [String: Any],
                  let calendar = calendars.first(where: { $0.id == args["calendar_id"] as? String && $0.providerType.rawValue == args["provider"] as? String }) else {
                throw ToolArgumentError(message: "A saved destination is no longer available. Nothing resumed.")
            }
            let draft = try CreateEventsTool.draft(args, defaultMinutes: defaultMinutes)
            targets.insert("\(calendar.name) · \(calendar.source)")
            choices.append(PageChoice(id: step.id.uuidString, label: step.title, note: CreateEventTool.when(draft)))
        }
        return CreateEventsTool.proposal(job, calendarLabel: targets.sorted().joined(separator: "; "), jobs: jobs, manager: manager, defaultMinutes: defaultMinutes, choices: choices)
    }
}
struct StandingFolderTool: AgentTool {
    let scheduled: Bool
    var name: String { scheduled ? "schedule_organize" : "watch_folder" }
    var description: String { scheduled ? "Schedule a granted folder for organization previews at a daily time. No automatic moves." : "Watch a granted folder and prepare organization previews when files arrive. No automatic moves." }
    let config: AssistantConfig?
    let roots: MarginRoots
    var parameters: [String: Any] { Self.schema(["folder": Self.string("Granted folder name or path"), "hour": Self.integer("Daily local hour, 0–23; default 9"), "minute": Self.integer("Daily minute, 0–59; default 0")], required: ["folder"]) }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        guard let config else { throw ToolArgumentError(message: "Folder jobs are unavailable in this session.") }
        guard let folder = roots.resolve(ToolArgs.string(a, "folder")), roots.isGranted(folder) else { throw ToolArgumentError(message: "Grant that folder from the notebook’s inside cover first.") }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw ToolArgumentError(message: "Choose a folder, not an individual file.") }
        let hour = ToolArgs.int(a, "hour") ?? 9, minute = ToolArgs.int(a, "minute") ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw ToolArgumentError(message: "Use a valid local hour and minute.") }
        return ProposedAction(kind: .change, title: scheduled ? "Schedule folder previews" : "Watch folder", details: [folder.path, scheduled ? String(format: "Daily at %02d:%02d · %@", hour, minute, TimeZone.current.identifier) : "When new files arrive", "Review every proposed move in File Organizer. The Mac and app must be running.", "Uses File Organizer’s configured model; file previews may be sent to that provider."], confirmLabel: scheduled ? "Schedule" : "Watch", run: { _ in
            guard roots.isGranted(folder) else { throw ToolArgumentError(message: "The folder grant was revoked.") }
            var job = OrganizeJob(); job.name = "Margin · \(folder.lastPathComponent)"
            job.sourceBookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            job.marginManaged = true; job.autoApply = false
            job.scheduleEnabled = scheduled; job.watchEnabled = !scheduled
            job.scheduleKind = .dailyAt; job.scheduleHour = hour; job.scheduleMinute = minute
            job.lastRunAt = Date() // first scheduled preview is at the next selected time, not a catch-up run now
            config.addJob(job)
            return "\(scheduled ? "Scheduled" : "Watching") \(folder.lastPathComponent). Reviews appear in File Organizer. Job \(job.id.uuidString)."
        })
    }
}

struct RecordingReadTool: AgentTool {
    enum Operation: String { case list = "list_recordings", search = "search_transcripts", notes = "generate_notes" }
    let operation: Operation
    var name: String { operation.rawValue }
    var description: String {
        switch operation {
        case .list: return "List recordings in a granted recording folder."
        case .search: return "Search existing transcript text in a granted recording folder; literal excerpts with filenames."
        case .notes: return "Queue transcript and notes generation for one exact recording filename, with confirmation."
        }
    }
    let recordingConfig: RecordingConfig?
    let pipeline: MeetingNotesPipeline?
    let roots: MarginRoots
    var parameters: [String: Any] { Self.schema(["folder": Self.string("Granted folder, defaults to configured recording folder"), "query": Self.string("Literal transcript search text"), "filename": Self.string("Exact recording filename for notes generation")]) }
    func workingPhrase(_ a: [String: Any]) -> String { operation == .search ? "Searching saved transcript text…" : "Reading the recording folder…" }
    @MainActor func prepare(_ a: [String: Any]) async throws -> ProposedAction {
        let directory: URL
        if let raw = ToolArgs.string(a, "folder"), let resolved = roots.resolve(raw) { directory = resolved }
        else if ToolArgs.string(a, "folder") != nil { throw ToolArgumentError(message: "That folder is not granted.") }
        else if let saved = recordingConfig?.resolveSaveDirectory() { directory = saved }
        else { throw ToolArgumentError(message: "Specify a granted recording folder.") }
        defer { directory.stopAccessingSecurityScopedResource() }
        guard roots.isGranted(directory) else { throw ToolArgumentError(message: "Grant the recording folder first: \(directory.path)") }
        let documents = RecordingDocument.scan(directory: directory).filter { roots.isGranted($0.audioURL) }
        if operation == .list {
            return .answer("Recordings", documents.isEmpty ? ["No .m4a recordings in \(directory.path)."] : documents.prefix(50).map {
                "\($0.audioURL.lastPathComponent)\nTranscript: \($0.hasTranscript ? "ready" : "none") · Notes: \($0.hasNotes ? "ready" : "none")\(pipeline?.state(for: $0).map { " · \($0)" } ?? "")"
            } + ["Showing \(min(documents.count, 50)) of \(documents.count) recordings."])
        }
        if operation == .search {
            guard let query = ToolArgs.string(a, "query"), query.count <= 500 else { throw ToolArgumentError(message: "Give a search phrase of up to 500 characters.") }
            var lines: [String] = []; var opened = 0; var skipped = 0
            for document in documents.prefix(50) where document.hasTranscript {
                guard roots.isGranted(document.transcriptURL), let size = try? document.transcriptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 2_000_000, let text = try? String(contentsOf: document.transcriptURL, encoding: .utf8) else { skipped += 1; continue }
                opened += 1
                if let range = text.range(of: query, options: .caseInsensitive) {
                    let start = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
                    let end = text.index(range.upperBound, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
                    lines.append("\(document.transcriptURL.lastPathComponent)\n…\(text[start..<end])…")
                }
            }
            return .answer("Transcript search", (lines.isEmpty ? ["No matches in the transcripts checked."] : lines) + ["Opened \(opened) transcripts; skipped \(skipped). Checked at most 50 recordings; files over 2 MB are skipped."])
        }
        guard let filename = ToolArgs.string(a, "filename"), let document = documents.first(where: { $0.audioURL.lastPathComponent == filename }), let pipeline else { throw ToolArgumentError(message: "Choose one exact filename from list_recordings.") }
        guard !document.hasTranscript, !document.hasNotes else { return .answer("Notes already present", ["This recording already has a transcript or notes. Open it in Meeting Notes to review or regenerate explicitly."]) }
        return ProposedAction(kind: .change, title: "Generate transcript and notes", details: [filename, "Uses your configured transcription engine and notes model. Audio or text may be sent to those configured providers. New sidecar files are saved beside the recording."], confirmLabel: "Generate", run: { _ in
            guard roots.isGranted(document.audioURL), roots.isGranted(document.transcriptURL), roots.isGranted(document.notesURL), !document.hasTranscript, !document.hasNotes else { throw ToolArgumentError(message: "Access or output files changed. Prepare a new preview.") }
            pipeline.enqueue(document, permission: { roots.isGranted(document.audioURL) && roots.isGranted(document.transcriptURL) && roots.isGranted(document.notesURL) })
            return "Queued \(filename). Follow progress with list_recordings or Meeting Notes; notes are not finished yet."
        })
    }
}
