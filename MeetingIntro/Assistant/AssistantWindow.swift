import AppKit
import SwiftUI

/// The Executive Assistant window (Issue #17): its own model config, saved folders,
/// "Organize now" → an approve-then-apply preview with per-file reasons, and undo history.
struct AssistantWindow: View {
    @ObservedObject var config: AssistantConfig
    @ObservedObject var organizer: FileOrganizer
    @ObservedObject var coordinator: FileOrganizerCoordinator

    @State private var proposals: [FileProposal] = []
    @State private var activeJob: OrganizeJob?
    @State private var editingJob: OrganizeJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                modelStatus
                if proposals.isEmpty {
                    foldersSection
                    if !config.undoBatches.isEmpty { undoSection }
                } else {
                    previewSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 580, minHeight: 500)
        .onAppear { loadPendingReview() }
        .onReceive(coordinator.$pendingReview.compactMap { $0 }) { _ in loadPendingReview() }
        .sheet(item: $editingJob) { job in
            AssistantJobEditSheet(
                job: job,
                onSave: { config.updateJob($0); editingJob = nil },
                onRepick: { repickFolder(for: job) },
                onCancel: { editingJob = nil })
        }
    }

    /// A scheduled/watch run published a review — load its proposals into the preview.
    private func loadPendingReview() {
        guard let pr = coordinator.pendingReview,
              let job = config.jobs.first(where: { $0.id == pr.jobID }) else { return }
        activeJob = job
        proposals = pr.proposals
        coordinator.pendingReview = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Executive Assistant", systemImage: "sparkles").font(.title2.weight(.semibold))
            Text("AI file organizer — proposes a tidy structure; nothing moves until you approve.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model (configured centrally in Settings → AI Models)

    private var modelStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: config.llmReady ? "cpu" : "exclamationmark.triangle.fill")
                .foregroundStyle(config.llmReady ? Color.secondary : Color.orange)
            if config.llmReady {
                Text("Model: \(config.provider.displayName) · \(config.modelID)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("No AI model set — add it in Settings → AI Models.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            SettingsLink { Text("Settings → AI Models…").font(.caption) }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Folders

    private var foldersSection: some View {
        GroupBox("Folders") {
            VStack(alignment: .leading, spacing: 8) {
                if config.jobs.isEmpty {
                    Text("Add a folder to organize (e.g. your Downloads).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(config.jobs) { job in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.name.isEmpty ? "Folder" : job.name).font(.callout)
                            Text(path(for: job)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let summary = automationSummary(job) {
                                Label(summary, systemImage: "bolt.horizontal").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Organize now") { organize(job) }.disabled(organizer.isPlanning || !config.llmReady)
                        Button { editingJob = job } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).help("Rename, schedule, watch…")
                        Button(role: .destructive) { config.removeJob(job.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }
                HStack {
                    Button { addFolder() } label: { Label("Add folder…", systemImage: "plus") }
                    if organizer.isPlanning { ProgressView().controlSize(.small); Text("Analyzing…").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                if let err = organizer.lastError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                }
                if !config.llmReady {
                    Text("Set a model + API key above first (or pick a keyless local provider).")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        GroupBox("Proposed changes — \(includedCount) of \(proposals.count) selected") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Select all") { setAll(true) }
                    Button("None") { setAll(false) }
                    Spacer()
                    Text("Nothing moves until you Apply.").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach($proposals) { $p in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $p.include).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.originalURL.lastPathComponent).font(.callout).lineLimit(1)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text((p.proposedFolder.isEmpty ? "" : p.proposedFolder + "/") + (p.willRename ? p.proposedName : p.originalURL.lastPathComponent))
                                    .font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            }
                            if !p.observedReason.isEmpty {
                                Label(p.observedReason, systemImage: "text.magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                            }
                            if p.willRename, !p.renameReason.isEmpty {
                                Label(p.renameReason, systemImage: "pencil").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Divider()
                }
                HStack {
                    Button("Cancel") { proposals = []; activeJob = nil }
                    Spacer()
                    Button("Apply \(includedCount)") { apply() }
                        .keyboardShortcut(.defaultAction).disabled(includedCount == 0)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Undo

    private var undoSection: some View {
        GroupBox("Recent runs") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(config.undoBatches.reversed()) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(batch.jobName) — \(batch.moves.count) file\(batch.moves.count == 1 ? "" : "s")").font(.callout)
                            Text(batch.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Undo") { organizer.undo(batch) }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private var includedCount: Int { proposals.filter(\.include).count }
    private func setAll(_ v: Bool) { for i in proposals.indices { proposals[i].include = v } }

    /// One-line summary of a job's enabled options, or nil if all off.
    private func automationSummary(_ job: OrganizeJob) -> String? {
        var parts: [String] = []
        if job.renameEnabled { parts.append("Rename") }
        if job.scheduleEnabled { parts.append("Every \(job.scheduleIntervalHours)h") }
        if job.watchEnabled { parts.append("Watch new files") }
        if job.autoApply { parts.append("Auto-apply") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func repickFolder(for job: OrganizeJob) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var j = job
        j.name = url.lastPathComponent
        j.sourceBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        config.updateJob(j)
        editingJob = j
    }

    private func path(for job: OrganizeJob) -> String {
        guard let data = job.sourceBookmark else { return "—" }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return "—" }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var job = OrganizeJob()
        job.name = url.lastPathComponent
        job.sourceBookmark = bookmark
        config.addJob(job)
    }

    private func organize(_ job: OrganizeJob) {
        activeJob = job
        Task { proposals = await organizer.plan(job) }
    }

    private func apply() {
        guard let job = activeJob else { return }
        _ = organizer.apply(proposals, job: job)
        proposals = []
        activeJob = nil
    }
}

/// Per-folder options (Issue #17, Phase 2): rename, and the automation triggers —
/// run on a schedule and/or when new files land, applied automatically or reviewed first.
struct AssistantJobEditSheet: View {
    let job: OrganizeJob
    let onSave: (OrganizeJob) -> Void
    let onRepick: () -> Void
    let onCancel: () -> Void

    @State private var renameEnabled = true
    @State private var autoApply = false
    @State private var scheduleEnabled = false
    @State private var scheduleIntervalHours = 24
    @State private var watchEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Folder options").font(.headline).padding(.top, 16)
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(job.name.isEmpty ? "—" : job.name).foregroundStyle(.secondary).lineLimit(1)
                            Button("Change…") { onRepick() }
                        }
                    }
                    Toggle("Propose cleaner filenames (rename)", isOn: $renameEnabled)
                }

                Section {
                    Toggle("Run on a schedule", isOn: $scheduleEnabled)
                    if scheduleEnabled {
                        Stepper("Every \(scheduleIntervalHours) hour\(scheduleIntervalHours == 1 ? "" : "s")",
                                value: $scheduleIntervalHours, in: 1...168)
                    }
                    Toggle("Watch for new files", isOn: $watchEnabled)
                } header: {
                    Text("Automation")
                } footer: {
                    Text(autoApply
                         ? "Automated runs apply changes immediately (undo stays available)."
                         : "Automated runs open a preview for you to approve first.")
                        .font(.caption)
                }

                if scheduleEnabled || watchEnabled {
                    Section {
                        Toggle("Apply automatically (skip the review)", isOn: $autoApply)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
        .onAppear(perform: load)
    }

    private func load() {
        renameEnabled = job.renameEnabled
        autoApply = job.autoApply
        scheduleEnabled = job.scheduleEnabled
        scheduleIntervalHours = job.scheduleIntervalHours
        watchEnabled = job.watchEnabled
    }

    private func save() {
        var j = job
        j.renameEnabled = renameEnabled
        j.autoApply = autoApply
        j.scheduleEnabled = scheduleEnabled
        j.scheduleIntervalHours = scheduleIntervalHours
        j.watchEnabled = watchEnabled
        onSave(j)
    }
}
