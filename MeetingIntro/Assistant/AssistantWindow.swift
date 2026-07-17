import AppKit
import SwiftUI

/// The Executive Assistant window (Issue #17): its own model config, saved folders,
/// "Organize now" → an approve-then-apply preview with per-file reasons, and undo history.
struct AssistantWindow: View {
    @ObservedObject var config: AssistantConfig
    @ObservedObject var organizer: FileOrganizer

    @State private var proposals: [FileProposal] = []
    @State private var activeJob: OrganizeJob?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                modelSection
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Executive Assistant", systemImage: "sparkles").font(.title2.weight(.semibold))
            Text("AI file organizer — proposes a tidy structure; nothing moves until you approve.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        GroupBox("Model") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: $config.provider) {
                    ForEach(QuickAddProvider.allCases) { Text($0.displayName).tag($0) }
                }
                if config.provider.needsKey {
                    SecureField(config.provider.keyPlaceholder, text: $config.key).textFieldStyle(.roundedBorder)
                }
                if config.provider == .custom {
                    TextField("API base URL (OpenAI-compatible)", text: $config.apiBaseURL).textFieldStyle(.roundedBorder)
                }
                HStack {
                    TextField("Model", text: $config.modelID).textFieldStyle(.roundedBorder)
                    Button(testing ? "Testing…" : "Test") { testModel() }
                        .disabled(testing || !config.llmReady)
                }
                if let testResult {
                    Text(testResult).font(.caption2).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red).lineLimit(2)
                }
            }
            .padding(6)
        }
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
                        }
                        Spacer()
                        Toggle("Rename", isOn: rename(job)).toggleStyle(.checkbox).font(.caption)
                        Button("Organize now") { organize(job) }.disabled(organizer.isPlanning || !config.llmReady)
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

    private func rename(_ job: OrganizeJob) -> Binding<Bool> {
        Binding(get: { job.renameEnabled }, set: { var j = job; j.renameEnabled = $0; config.updateJob(j) })
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

    private func testModel() {
        testing = true
        testResult = nil
        Task {
            do {
                let r = try await LLMClient.complete(system: "Reply with the single word: OK", user: "test",
                                                     baseURL: config.apiBaseURL, key: config.key, model: config.modelID)
                testResult = "✓ " + r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            } catch {
                testResult = "✗ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            testing = false
        }
    }
}
