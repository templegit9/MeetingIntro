import SwiftUI

struct MarginSettingsView: View {
    @ObservedObject var config: MarginConfig
    @ObservedObject var agent: MarginAgent
    @ObservedObject var nudges: MarginNudgeEngine
    @ObservedObject var history: MarginHistory
    let openNotebook: () -> Void
    let done: () -> Void
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Margin").font(.title2.bold())
                    Text("Make the notebook feel like yours.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open notebook", action: openNotebook)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }.padding(20)
            Form {
                Section {
                    MarginAISetupStatus(config: config, setup: agent.localAI)
                } header: {
                    SettingsSectionHeader("Local AI", info: "Margin prepares AI on this Mac automatically. Downloads are kept across updates. First-time preparation checks compatibility and storage before downloading. Disabling Margin stops the engine it owns; an existing AI service is left running.")
                }
                Section {
                    MarginJobReviewView(store: agent.jobs)
                } header: {
                    SettingsSectionHeader("Interrupted jobs", info: "If a connection fails during a write, Margin cannot know whether it reached the calendar. Check the destination before marking the step as created or not created. A not-created step still requires a fresh resume preview and confirmation.")
                }

                Section {
                    Picker("Voice", selection: $config.personality) {
                        ForEach(MarginConfig.Personality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text(config.personality.instruction).font(.caption).foregroundStyle(.secondary)
                    Toggle("Let Margin’s soul evolve", isOn: $config.evolutionEnabled)
                    Text("Your instructions · always take priority").font(.subheadline)
                    TextEditor(text: $config.soul).font(.body).frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                        .accessibilityLabel("Soul instructions")
                } header: {
                    SettingsSectionHeader("Personality", info: "Soul instructions apply alongside your selected voice. For example: Be concise, challenge unclear requests, and explain your assumptions. Up to 2,000 characters. Preferences cannot grant new access or bypass confirmation.")
                }
                Section {
                    Toggle("Learn and use memory", isOn: $config.memoryEnabled)
                    Text("Preferences to remember").font(.subheadline)
                    TextEditor(text: $config.memoryNotes).font(.body).frame(minHeight: 65)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3)))
                        .accessibilityLabel("Preferences to remember")
                    if !config.learningStatus.isEmpty { Text(config.learningStatus).font(.caption).foregroundStyle(.secondary) }
                    ForEach(config.learned) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.kind == "soul" ? "Soul · \(entry.key)" : "Memory · \(entry.key)").font(.subheadline.bold())
                                Spacer()
                                if entry.pinned { Text("Pinned").font(.caption) }
                                Button("Forget") { config.forget(entry.id) }
                            }
                            TextField("Learned preference", text: Binding(get: {
                                config.learned.first(where: { $0.id == entry.id })?.value ?? ""
                            }, set: { config.editLearned(entry.id, value: $0) }))
                            Text("Learned from: “\(entry.evidence)”").font(.caption).foregroundStyle(.secondary)
                            if let previous = entry.previous { Text("Previously: \(previous)").font(.caption).foregroundStyle(.secondary) }
                            Text(entry.updated, style: .date).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    Toggle("Save conversations on this Mac", isOn: $config.saveHistory)
                    Picker("Keep saved conversations", selection: $config.historyDays) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    Button("Clear saved history…", role: .destructive) { confirmClear = true }
                        .disabled(history.entries.isEmpty && history.problem == nil)
                    if let problem = history.problem { Text(problem).foregroundStyle(.orange) }
                } header: {
                    SettingsSectionHeader("Memory", info: "Margin learns durable preferences from your messages using the configured local model, after answering. Memory and soul can evolve independently; pause either with its switch. Your explicit notes take priority. Learned entries show their evidence and previous value. Editing pins an entry; Forget removes it and blocks relearning that category. Turning learning off also stops using that learned state. Conversation saving is separate.\n\nThe Index stores local text receipts: up to 100 conversations with 100 entries each. Turning saving off keeps existing history until its retention limit or until you clear it.")
                }
                Section {
                    Picker("When to help", selection: $config.proactivity) {
                        ForEach(MarginConfig.Proactivity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text(proactivityDescription).font(.caption).foregroundStyle(.secondary)
                    if config.proactivity == .helpful {
                        Stepper("Up to \(config.foldedCornerBudget) nudges per day", value: $config.foldedCornerBudget, in: 1...10)
                    }
                    Toggle("Pause proactive suggestions", isOn: $config.banded)
                } header: {
                    SettingsSectionHeader("Proactivity", info: "Suggestions require your confirmation before anything changes. Gentle nudges appear only during a gap in your day, within the daily budget. Individual watches are on the inside cover.")
                }
                Section {
                    Toggle("⌥Space opens Margin", isOn: $config.summonShortcutEnabled)
                    Picker("Rest after no input", selection: $config.idleSeconds) {
                        Text("30 seconds").tag(30); Text("1 minute").tag(60)
                        Text("2 minutes").tag(120); Text("5 minutes").tag(300)
                        Text("Never").tag(0)
                    }
                    HStack { Text("Resting opacity"); Slider(value: $config.restingOpacity, in: 0.15...1) }
                } header: {
                    SettingsSectionHeader("Notebook", info: "After inactivity, Margin closes to the small transparent notebook cover. Click the cover or press ⌥Space to reopen the same page and draft. Hovering leaves the resting cover transparent. Margin stays visible while preparing or executing an action. Granted folders and individual watches are managed on the inside cover.")
                }
            }.formStyle(.grouped)
        }
        .frame(width: 590, height: 690)
        .onChange(of: config.soul) { _, text in if text.count > 2000 { config.soul = String(text.prefix(2000)) } }
        .onChange(of: config.memoryNotes) { _, text in if text.count > 2000 { config.memoryNotes = String(text.prefix(2000)) } }
        .onChange(of: config.saveHistory) { _, _ in agent.saveConversation() }
        .onChange(of: config.historyDays) { _, days in history.prune(days: days) }
        .onChange(of: config.proactivity) { _, _ in nudges.evaluate() }
        .onChange(of: config.banded) { _, _ in nudges.evaluate() }
        .confirmationDialog("Clear saved conversation history?", isPresented: $confirmClear) {
            Button("Clear saved history", role: .destructive) { history.clear() }
        } message: {
            Text("This removes the local archive. Your current page and saved preferences remain.")
        }
    }

    private var proactivityDescription: String {
        switch config.proactivity {
        case .quiet: return "Respond only when you ask. No ribbons or folded corners."
        case .ribbon: return "Keep suggestions on the ribbon for when you open the notebook."
        case .helpful: return "Offer a folded corner during a gap in your day, within your daily limit."
        }
    }
}

struct MarginHistoryView: View {
    @ObservedObject var history: MarginHistory
    @ObservedObject var agent: MarginAgent
    @ObservedObject var config: MarginConfig
    var onClose: () -> Void
    @Binding var savedOnly: Bool
    @State private var query = ""

    private var matches: [MarginHistory.Entry] {
        history.entries.filter { entry in
            (!savedOnly || entry.bookmark != nil) && (query.isEmpty || entry.displayTitle.localizedCaseInsensitiveContains(query)
                || entry.turns.contains { $0.text.localizedCaseInsensitiveContains(query) })
        }
    }
    private var days: [Date] {
        Array(Set(matches.map { Calendar.current.startOfDay(for: $0.updated) })).sorted(by: >)
    }
    private func heading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INDEX  \(history.entries.count) PAGES")
                .font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(MarginTheme.inkSoft).padding(.top, 17).padding(.bottom, 12)
            Picker("Pages", selection: $savedOnly) {
                Text("All history").tag(false)
                Text("Saved (\(history.bookmarks.count))").tag(true)
            }.pickerStyle(.segmented).padding(.bottom, 10)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField("Look for a page…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(9).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(MarginTheme.rule, lineWidth: 1))
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if !config.saveHistory {
                        Text("Saving is off. Turn on saved pages in Margin settings to keep new requests.")
                            .font(.system(size: 11)).foregroundStyle(MarginTheme.inkSoft)
                    }
                    if let problem = history.problem { Text(problem).font(.caption).foregroundStyle(MarginTheme.amberInk) }
                    if matches.isEmpty {
                        Text(query.isEmpty ? "Your saved pages will appear here." : "No pages match your search.")
                            .font(.system(size: 12)).foregroundStyle(MarginTheme.inkSoft).padding(.vertical, 12)
                    }
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 11) {
                            HStack(spacing: 8) {
                                Text(heading(day)).font(.system(size: 9, weight: .semibold)).tracking(1.4)
                                Rectangle().fill(MarginTheme.rule).frame(height: 0.5)
                            }.foregroundStyle(MarginTheme.inkSoft)
                            ForEach(matches.filter { Calendar.current.isDate($0.updated, inSameDayAs: day) }) { entry in
                                Button {
                                    agent.openConversation(entry); onClose()
                                } label: {
                                    HStack(spacing: 10) {
                                        if let mark = entry.bookmark {
                                            RoundedRectangle(cornerRadius: 2).fill(mark.color.ink).frame(width: 7, height: 22)
                                        }
                                        Circle().fill(entry.performed ? MarginTheme.cloth : MarginTheme.inkSoft.opacity(0.28))
                                            .frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.displayTitle).font(.system(size: 12)).lineLimit(2)
                                            Text(entry.summary).font(.system(size: 10)).foregroundStyle(MarginTheme.inkSoft).lineLimit(2)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Text(entry.updated.formatted(date: .omitted, time: .shortened))
                                            .font(.system(size: 10)).foregroundStyle(MarginTheme.inkSoft)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(agent.isBusy)
                                    .help("\(entry.displayTitle) — \(entry.summary)")
                                    .contextMenu {
                                        ForEach(MarginHistory.RibbonColor.allCases) { choice in
                                            Button("\(choice.rawValue.capitalized) ribbon") { history.mark(entry.id, color: choice) }
                                        }
                                        if entry.bookmark != nil { Button("Remove ribbon") { history.unmark(entry.id) } }
                                    }
                                    .accessibilityLabel("\(entry.title). \(entry.summary). \(entry.performed ? "Action performed" : "No action performed")")
                            }
                        }
                    }
                }.padding(.bottom, 16)
            }
            Divider().overlay(MarginTheme.rule)
            Text("Pages with a green dot did something. Grey ones were only answers or unconfirmed proposals.")
                .font(.system(size: 10)).foregroundStyle(MarginTheme.inkSoft).padding(.vertical, 11)
            Divider().overlay(MarginTheme.rule)
            HStack {
                Text("⌘K to return").font(.system(size: 10)).foregroundStyle(MarginTheme.inkSoft)
                Spacer()
                Button("New page") { agent.newConversation(); onClose() }
                    .font(.system(size: 11)).buttonStyle(.plain).disabled(agent.isThinking)
            }.padding(.vertical, 12)
        }.padding(.horizontal, 14).foregroundStyle(MarginTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MarginTheme.paper)
            .onAppear { history.prune(days: config.historyDays) }
    }
}

/// Live state from the journal, not a synthetic percentage or model-generated progress.
struct MarginJobProgressView: View {
    @ObservedObject var store: MarginJobStore
    @State private var error: String?
    var body: some View {
        if let job = store.jobs.first(where: { $0.state == "running" }) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(job.steps.filter { $0.state == "completed" }.count) of \(job.steps.count) steps completed")
                    .font(.system(size: 12, weight: .semibold))
                if let step = job.steps.first(where: { $0.state == "running" }) {
                    Text("Working on: \(step.title)").font(.system(size: 11))
                }
                Button("Pause after current step") {
                    do { try store.pause(job.id) } catch { self.error = error.localizedDescription }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(MarginTheme.cloth)
                if let error { Text(error).font(.caption) }
            }.foregroundStyle(MarginTheme.inkSoft).padding(.vertical, 6)
        }
    }
}

struct MarginJobReviewView: View {
    @ObservedObject var store: MarginJobStore
    @State private var pending: (job: UUID, step: UUID, created: Bool)?
    @State private var error: String?
    private var uncertain: [(MarginJobStore.Job, MarginJobStore.Step)] {
        store.jobs.flatMap { job in job.steps.filter { $0.state == "uncertain" }.map { (job, $0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if uncertain.isEmpty { Text("No uncertain steps to review.").foregroundStyle(.secondary) }
            ForEach(uncertain, id: \.1.id) { job, step in
                VStack(alignment: .leading, spacing: 5) {
                    Text(step.title).font(.headline)
                    if let destination = step.destination { Text(destination).font(.caption) }
                    if let args = try? JSONSerialization.jsonObject(with: step.arguments) as? [String: Any],
                       let date = ToolArgs.string(args, "start") { Text(date).font(.caption) }
                    Text(step.result ?? "Result uncertain.").font(.caption)
                    HStack {
                        Button("Already created") { pending = (job.id, step.id, true) }
                        Button("Not created") { pending = (job.id, step.id, false) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
        }
        .confirmationDialog("Have you checked this event in the destination calendar?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("I checked — record this result") {
                guard let pending else { return }
                do { try store.resolve(pending.job, stepID: pending.step, wasCreated: pending.created) }
                catch { self.error = error.localizedDescription }
                self.pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.created == true ? "This step will be marked completed and will not run again." : "This step will become pending. Ask Margin to list your jobs, then resume this one for a fresh preview before any write.")
        }
    }
}
