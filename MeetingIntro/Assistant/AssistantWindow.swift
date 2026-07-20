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
    @State private var activeMode: OrganizeMode = .organize
    @State private var editingJob: OrganizeJob?
    @State private var editingRule: OrganizeRule?
    /// Pending folder-group renames (oldName → typed text), applied on submit / Apply so
    /// typing doesn't re-bucket the list on every keystroke.
    @State private var groupNameEdits: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                modelStatus
                if proposals.isEmpty {
                    foldersSection
                    instructionsSection
                    rulesSection
                    if !config.undoBatches.isEmpty { undoSection }
                } else {
                    previewSection
                }
            }
            .padding(20)
        }
        .frame(minWidth: 580, minHeight: 520)
        .onAppear { loadPendingReview() }
        .onReceive(coordinator.$pendingReview.compactMap { $0 }) { _ in loadPendingReview() }
        .sheet(item: $editingJob) { job in
            AssistantJobEditSheet(
                job: job,
                onSave: { config.updateJob($0); editingJob = nil },
                onRepick: { repickFolder(for: job) },
                onCancel: { editingJob = nil })
        }
        .sheet(item: $editingRule) { rule in
            AssistantRuleEditSheet(
                rule: rule,
                onSave: { saved in
                    if config.rules.contains(where: { $0.id == saved.id }) { config.updateRule(saved) } else { config.addRule(saved) }
                    editingRule = nil
                },
                onDelete: config.rules.contains(where: { $0.id == rule.id }) ? { config.removeRule(rule.id); editingRule = nil } : nil,
                onCancel: { editingRule = nil })
        }
    }

    /// A scheduled/watch run published a review — load its proposals into the preview.
    private func loadPendingReview() {
        guard let pr = coordinator.pendingReview,
              let job = config.jobs.first(where: { $0.id == pr.jobID }) else { return }
        activeJob = job
        activeMode = .organize
        proposals = pr.proposals
        coordinator.pendingReview = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("File Organizer", systemImage: "folder.badge.gearshape").font(.title2.weight(.semibold))
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
                        Menu {
                            Button("Organize (top-level)") { organize(job, mode: .organize) }
                            Button("Re-organize (all nested files)") { organize(job, mode: .reorganize) }
                            Divider()
                            Button("Find duplicates") { scanDuplicates(job) }
                        } label: {
                            Text("Organize")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(organizer.isPlanning)
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

    // MARK: - Preferences (instructions + auto-apply cap)

    private var instructionsSection: some View {
        GroupBox("Preferences") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tell the AI how you like things filed — applied to every run.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("e.g. invoices → Finance; keep code projects together; screenshots by month",
                          text: $config.instructions, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                Divider().padding(.vertical, 2)
                Stepper(value: $config.autoApplyMaxFiles, in: 5...1000, step: 5) {
                    Text("Auto-apply safety limit: \(config.autoApplyMaxFiles) files")
                }
                Text("Automated runs bigger than this — or any that would Trash files — pause for review instead of applying.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        GroupBox("Rules") {
            VStack(alignment: .leading, spacing: 6) {
                if config.rules.isEmpty {
                    Text("Rules run before the AI (predictable + cheaper) — e.g. “*.dmg → Trash”, “name contains screenshot → Skip”, “*.pdf → Documents”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(config.rules) { rule in
                    HStack(spacing: 8) {
                        Image(systemName: "checklist").foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name.isEmpty ? rule.summary : rule.name).font(.callout).lineLimit(1)
                                .foregroundStyle(rule.enabled ? .primary : .secondary)
                            Text(rule.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingRule = rule }.buttonStyle(.borderless)
                        Button(role: .destructive) { config.removeRule(rule.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }
                HStack {
                    Button { editingRule = OrganizeRule() } label: { Label("Add rule", systemImage: "plus") }
                    Spacer()
                }
            }
            .padding(6)
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        GroupBox("Proposed changes — \(includedCount) of \(proposals.count) selected") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Select all") { setAll(true) }
                    Button("None") { setAll(false) }
                    Spacer()
                    Text(activeMode == .reorganize
                         ? "Re-organize — pulls files out of subfolders; empty folders get removed. Nothing changes until Apply."
                         : "Nothing moves until you Apply.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(privacyCaption).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)

                if !trashProposals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Move to Trash", systemImage: "trash").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        ForEach(trashProposals) { proposalRow($0) }
                    }
                    Divider()
                }

                ForEach(proposalGroups, id: \.self) { folder in
                    let inGroup = proposals.filter { $0.action == .move && $0.proposedFolder == folder }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            TextField("Folder", text: Binding(
                                get: { groupNameEdits[folder] ?? folder },
                                set: { groupNameEdits[folder] = $0 }))
                                .textFieldStyle(.roundedBorder).font(.callout.weight(.medium)).frame(maxWidth: 220)
                                .onSubmit { commitGroupRename(folder) }
                            Text("\(inGroup.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(inGroup) { proposalRow($0) }
                    }
                    Divider()
                }

                HStack {
                    Button("Cancel") { proposals = []; activeJob = nil; groupNameEdits = [:] }
                    Spacer()
                    Button(applyLabel) { apply() }
                        .keyboardShortcut(.defaultAction).disabled(includedCount == 0)
                }
            }
            .padding(6)
        }
    }

    private var applyLabel: String {
        let t = trashProposals.filter(\.include).count
        return t > 0 ? "Apply \(includedCount) (incl. \(t) → Trash)" : "Apply \(includedCount)"
    }

    /// Where the analysis happened + what left the Mac.
    private var privacyCaption: String {
        let usedAI = proposals.contains { $0.ruleName == nil }   // any model-produced proposal
        if !usedAI { return "No AI used — this ran entirely on your Mac." }
        let p = config.provider
        if p == .ollama || !p.needsKey {
            return "Analyzed with \(p.displayName) — everything stayed on this Mac."
        }
        return "Analyzed with \(p.displayName) · \(config.modelID) — file names + short content previews were sent to \(p.displayName)."
    }

    /// One preview row — editable file name (for moves) + reasons + Save-as-rule.
    private func proposalRow(_ p: FileProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: bindingInclude(p.id)).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.originalURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if p.action == .move {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        TextField("name", text: bindingName(p.id))
                            .textFieldStyle(.roundedBorder).font(.caption).frame(maxWidth: 200)
                    }
                }
                if !p.observedReason.isEmpty {
                    Label(p.observedReason, systemImage: p.ruleName != nil ? "checklist" : "text.magnifyingglass")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if p.action == .move, p.willRename, !p.renameReason.isEmpty {
                    Label(p.renameReason, systemImage: "pencil").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if p.action == .move, p.ruleName == nil {
                Button("Save as rule") { saveAsRule(p) }.font(.caption2).buttonStyle(.link)
            }
        }
    }

    private func commitGroupRename(_ folder: String) {
        guard let new = groupNameEdits[folder]?.trimmingCharacters(in: .whitespaces), !new.isEmpty, new != folder else {
            groupNameEdits[folder] = nil; return
        }
        renameGroup(folder, to: new)
        groupNameEdits[folder] = nil
    }

    private func flushGroupEdits() {
        for (old, _) in groupNameEdits { commitGroupRename(old) }
    }

    // MARK: - Undo

    private var undoSection: some View {
        GroupBox("Recent runs") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(config.undoBatches.reversed()) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(batch.jobName) — \(batch.totalActions) file\(batch.totalActions == 1 ? "" : "s")").font(.callout)
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
        if job.scheduleEnabled {
            if (job.scheduleKind ?? .interval) == .dailyAt {
                parts.append(String(format: "Daily %02d:%02d", job.scheduleHour ?? 9, job.scheduleMinute ?? 0))
            } else {
                parts.append("Every \(job.scheduleIntervalHours)h")
            }
        }
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

    private func organize(_ job: OrganizeJob, mode: OrganizeMode) {
        activeJob = job
        activeMode = mode
        Task { proposals = await organizer.plan(job, mode: mode) }
    }

    private func scanDuplicates(_ job: OrganizeJob) {
        activeJob = job
        activeMode = .organize   // duplicates only Trash; no folder pruning needed
        proposals = organizer.findDuplicates(job)
    }

    private func apply() {
        guard let job = activeJob else { return }
        flushGroupEdits()   // apply any typed-but-not-submitted folder renames
        _ = organizer.apply(proposals, job: job, mode: activeMode)
        proposals = []
        activeJob = nil
        groupNameEdits = [:]
    }

    // MARK: - Proposal editing helpers (grouped preview)

    /// Distinct target folders in the current proposals, in first-seen order (move actions).
    private var proposalGroups: [String] {
        var seen = Set<String>(), order: [String] = []
        for p in proposals where p.action == .move {
            if seen.insert(p.proposedFolder).inserted { order.append(p.proposedFolder) }
        }
        return order
    }

    private var trashProposals: [FileProposal] { proposals.filter { $0.action == .trash } }

    /// Rename a whole group's target folder (re-files every file in it).
    private func renameGroup(_ oldName: String, to newName: String) {
        for i in proposals.indices where proposals[i].action == .move && proposals[i].proposedFolder == oldName {
            proposals[i].proposedFolder = newName
        }
    }

    private func bindingName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { proposals.first(where: { $0.id == id })?.proposedName ?? "" },
            set: { v in if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].proposedName = v } })
    }

    private func bindingInclude(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { proposals.first(where: { $0.id == id })?.include ?? false },
            set: { v in if let i = proposals.firstIndex(where: { $0.id == id }) { proposals[i].include = v } })
    }

    /// Turn a corrected proposal into a rule (`.ext` of this file → its folder).
    private func saveAsRule(_ p: FileProposal) {
        let ext = p.originalURL.pathExtension
        guard !ext.isEmpty, !p.proposedFolder.isEmpty else { return }
        var rule = OrganizeRule()
        rule.name = "\(ext) → \(p.proposedFolder)"
        rule.match = RuleMatch(kind: .ext, pattern: ext)
        rule.action = .folder(p.proposedFolder)
        config.addRule(rule)
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
    @State private var scheduleKind: ScheduleKind = .interval
    @State private var scheduleIntervalHours = 24
    @State private var scheduleTime = Date()
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
                        Picker("Schedule", selection: $scheduleKind) {
                            Text("Every N hours").tag(ScheduleKind.interval)
                            Text("Daily at").tag(ScheduleKind.dailyAt)
                        }
                        if scheduleKind == .interval {
                            Stepper("Every \(scheduleIntervalHours) hour\(scheduleIntervalHours == 1 ? "" : "s")",
                                    value: $scheduleIntervalHours, in: 1...168)
                        } else {
                            DatePicker("Time", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        }
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
        scheduleKind = job.scheduleKind ?? .interval
        scheduleIntervalHours = job.scheduleIntervalHours
        scheduleTime = Calendar.current.date(bySettingHour: job.scheduleHour ?? 9, minute: job.scheduleMinute ?? 0, second: 0, of: Date()) ?? Date()
        watchEnabled = job.watchEnabled
    }

    private func save() {
        var j = job
        j.renameEnabled = renameEnabled
        j.autoApply = autoApply
        j.scheduleEnabled = scheduleEnabled
        j.scheduleKind = scheduleKind
        j.scheduleIntervalHours = scheduleIntervalHours
        let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
        j.scheduleHour = comps.hour
        j.scheduleMinute = comps.minute
        j.watchEnabled = watchEnabled
        onSave(j)
    }
}

/// Create/edit an organize rule (v2.14.0) — match by extension / name-contains / regex →
/// file into a folder, skip, or Trash. Runs before the AI.
struct AssistantRuleEditSheet: View {
    let rule: OrganizeRule
    let onSave: (OrganizeRule) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var enabled = true
    @State private var matchKind: RuleMatch.Kind = .ext
    @State private var pattern = ""
    @State private var actionKind = 0   // 0 = folder, 1 = skip, 2 = trash
    @State private var folder = ""

    var body: some View {
        VStack(spacing: 0) {
            Text(onDelete == nil ? "New Rule" : "Edit Rule").font(.headline).padding(.top, 16)
            Form {
                Section {
                    TextField("Rule name (optional)", text: $name).textFieldStyle(.roundedBorder)
                    Toggle("Enabled", isOn: $enabled)
                }
                Section("Match files where") {
                    Picker("Match by", selection: $matchKind) {
                        Text("Extension").tag(RuleMatch.Kind.ext)
                        Text("Name contains").tag(RuleMatch.Kind.nameContains)
                        Text("Name matches regex").tag(RuleMatch.Kind.regex)
                        Text("The file is… (AI)").tag(RuleMatch.Kind.ai)
                    }
                    TextField(placeholder, text: $pattern).textFieldStyle(.roundedBorder)
                    if matchKind == .ai {
                        Text("Described in plain language and judged by the AI from the file's content — e.g. “a tax document”, “a screenshot of a receipt”.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section("Then") {
                    Picker("Action", selection: $actionKind) {
                        Text("File into folder").tag(0)
                        Text("Skip").tag(1)
                        Text("Trash").tag(2)
                    }.pickerStyle(.segmented)
                    if actionKind == 0 {
                        TextField("Folder name", text: $folder).textFieldStyle(.roundedBorder)
                    } else if actionKind == 2 {
                        Text("Matching files move to the macOS Trash (undoable).").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let onDelete { Button("Delete", role: .destructive) { onDelete() } }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty
                              || (actionKind == 0 && folder.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
        .onAppear(perform: load)
    }

    private var placeholder: String {
        switch matchKind {
        case .ext: return "e.g. pdf"
        case .nameContains: return "e.g. invoice"
        case .regex: return #"e.g. ^IMG_\d+"#
        case .ai: return "e.g. a resume or CV"
        }
    }

    private func load() {
        name = rule.name
        enabled = rule.enabled
        matchKind = rule.match.kind
        pattern = rule.match.pattern
        switch rule.action {
        case .folder(let f): actionKind = 0; folder = f
        case .skip: actionKind = 1
        case .trash: actionKind = 2
        }
    }

    private func save() {
        var r = rule
        r.name = name.trimmingCharacters(in: .whitespaces)
        r.enabled = enabled
        r.match = RuleMatch(kind: matchKind, pattern: pattern.trimmingCharacters(in: .whitespaces))
        switch actionKind {
        case 1: r.action = .skip
        case 2: r.action = .trash
        default: r.action = .folder(folder.trimmingCharacters(in: .whitespaces))
        }
        onSave(r)
    }
}
