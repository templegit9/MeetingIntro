import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// The opened notebook.
///
/// Built to the nine fixes from the design review, and the rule underneath them: **every
/// page ends in at most two actions and says why it says what it says. If a page has
/// neither, it isn't finished.**
///
/// The two that changed the structure rather than the styling:
/// - *an answer you can't act on makes the assistant a search box* — slots are selectable
///   rows ending in one primary action, so a question becomes a held slot in two
///   keystrokes;
/// - *chrome and paper never share a surface* — the title bar, the close button and the
///   watches control left the page. The date is the page's own kicker; the controls live
///   on the spine's context menu, off the paper.
struct MarginPageView: View {

    @ObservedObject var agent: MarginAgent
    @ObservedObject var config: MarginConfig
    @ObservedObject var images: MarginImageDraft
    var ribbon: [MarginNudge] = []
    var roots: MarginRoots?
    var games: MarginPocketGames? = nil
    var onWatches: () -> Void = {}
    var onGames: () -> Void = {}
    let onClose: () -> Void
    /// Probe mode: the same stack, laid out unbounded so its true height can be measured.
    /// Fix 7 — the page ends where the answer ends, and a panel can only do that if
    /// something measures the answer first.
    var measuring = false

    @Binding var input: String
    @State private var expandedRequests: Set<UUID> = []
    @Binding var showingHistory: Bool
    @State private var historySavedOnly = false
    @State private var sheen = false
    @State private var gameHint: String?
    @FocusState private var writing: Bool

    /// Rule pitch. Fix 8: text is laid out on this rhythm, so ink sits *on* the line
    /// instead of floating between lines drawn to a different beat.
    private static let rulePitch: CGFloat = 25

    var body: some View {
        if measuring {
            pageStack.frame(width: MarginTheme.openWidth - 42).padding(.horizontal, 14).padding(.vertical, 14)
        } else {
            page
        }
    }

    /// Height this content needs at the page's real width, plus the writing line.
    @MainActor static func fittingHeight(agent: MarginAgent, config: MarginConfig,
                                         ribbon: [MarginNudge]) -> CGFloat {
        let probe = NSHostingView(rootView: MarginPageView(agent: agent, config: config, images: agent.imageDraft,
                                                           ribbon: ribbon, onClose: {},
                                                           measuring: true, input: .constant(""), showingHistory: .constant(false)))
        probe.frame = NSRect(x: 0, y: 0, width: MarginTheme.openWidth, height: 2000)
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize.height + 44
    }

    private var page: some View {
        HStack(spacing: 0) {
            spine
            VStack(alignment: .leading, spacing: 0) {
                if showingHistory {
                    MarginHistoryView(history: agent.history, agent: agent, config: config,
                                      onClose: { showingHistory = false }, savedOnly: $historySavedOnly)
                } else if images.active {
                    MarginImagePreviewPage(draft: images, request: input, cancelReading: { agent.cancelRequest() }, chooseDestination: { agent.chooseImageDestination() }, saveExport: { agent.saveImageExport() }, undoExport: { agent.undoImageExport() }, conversation: AnyView(pageStack))
                    Divider().overlay(MarginTheme.rule)
                    writingLine
                } else {
                    content
                    Divider().overlay(MarginTheme.rule)
                    writingLine
                }
            }
            .background(paper)
            MarginSavedRibbons(history: agent.history, agent: agent, imageRequest: input,
                openSavedIndex: { historySavedOnly = true; showingHistory = true },
                closeIndex: { showingHistory = false })
        }
        .background(MarginTheme.paper)
        // Fix 1: square on the spine edge, rounded on the other three. A notebook page is
        // bound on one side; a dialog is rounded on four.
        .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0,
                         bottomTrailingRadius: 9, topTrailingRadius: 9))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 9, topTrailingRadius: 9)
                .stroke(MarginTheme.clothDark.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: showingHistory ? .topTrailing : .topLeading) {
            if showingHistory {
                RoundedRectangle(cornerRadius: 3).fill(MarginTheme.ribbon)
                    .frame(width: 8, height: 37).padding(.trailing, 23).allowsHitTesting(false)
            } else { hangingRibbon }
        }
        .overlay(alignment: .topTrailing) {
            Button(showingHistory ? "Current page" : "Index") { showingHistory.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain).padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(.white).background(MarginTheme.cloth, in: RoundedRectangle(cornerRadius: 4))
                .offset(y: -14).help("Saved conversations")
                .disabled(agent.isThinking)
        }
        .onDrop(of: MarginImageDraft.dropTypes + ["public.text"], isTargeted: nil) { providers in
            guard !agent.isBusy else { return false }
            if providers.contains(where: { p in MarginImageDraft.dropTypes.contains(where: { p.hasItemConformingToTypeIdentifier($0) }) }) { return images.receive(providers) }
            guard !agent.isBusy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let text = object as? String, text == "margin-save-current" else { return }
                Task { @MainActor in agent.bookmarkCurrentPage(color: .red, imageRequest: input) }
            }
            return true
        }
        .onPasteCommand(of: [.png, .jpeg, .heic, .tiff]) { providers in if !agent.isBusy { _ = images.receive(providers) } }
        .environment(\.colorScheme, .light)
        .onAppear { writing = true }
        .task {
            await agent.checkAvailability()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !agent.isBusy, input.isEmpty, !agent.readingHistory,
                  !config.banded, config.proactivity != .quiet,
                  !agent.turns.contains(where: { $0.action?.kind == .change && $0.outcome == nil }) else { return }
            gameHint = games?.claimHint()
        }
        .onExitCommand { if showingHistory { showingHistory = false } else if images.active { if images.inspected { images.inspected = false } else { images.active = false } } else { onClose() } }
        .padding(.top, 18)
    }

    /// Fix 1: the spine. Eleven points of cloth down the bound edge — the whole difference
    /// between a notebook page and a beige dialog.
    private var spine: some View {
        LinearGradient(colors: [MarginTheme.cloth, MarginTheme.clothDark],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 11)
            // State lives on the cloth, never on the paper — the spec's rule. A slow
            // sheen travels the spine while it works, and nothing moves where you read.
            .overlay(alignment: .top) {
                if agent.isThinking {
                    LinearGradient(colors: [.clear, MarginTheme.paper.opacity(0.42), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .offset(y: sheen ? 420 : -80)
                        .animation(.linear(duration: 1.7).repeatForever(autoreverses: false), value: sheen)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .onChange(of: agent.isThinking) { _, working in
                sheen = false
                if working { DispatchQueue.main.async { sheen = true } }
            }
            .contextMenu {
                // Fix 3's other half: the controls that used to sit on the paper.
                Button("Image page…") { images.active = true }
                if ProcessInfo.processInfo.environment["MARGIN_IMAGE_UI_DEVELOPER"] == "1" {
                    Menu("Image UI fixtures") {
                        Button("Diagram") { images.sample("Diagram") }
                        Button("Eight holidays") { images.sample("Holidays") }
                    }
                }
                Button("Import image…") { images.choose() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Files · folders, rules and undo…") {
                    NotificationCenter.default.post(name: Notification.Name("MarginOpenFiles"), object: nil)
                }
                Button("What it's watching") { onWatches() }
                Toggle("Band it — won't speak first", isOn: Binding(
                    get: { config.banded }, set: { config.banded = $0 }))
                Divider()
                Button("A little diversion…") { onGames() }
                Button("Close") { onClose() }
            }
    }

    /// The ribbon hangs over the top edge, where a real one is sewn into the spine.
    private var hangingRibbon: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(ribbon.isEmpty ? MarginTheme.ribbon : MarginTheme.ribbonAmber)
            .frame(width: 6, height: 22)
            .offset(x: 22, y: -7)
    }

    private var pageStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            if agent.readingHistory {
                Text("Saved conversation · actions are inactive").font(.caption).foregroundStyle(MarginTheme.inkSoft)
                Button("Back to current page") { agent.returnToCurrentConversation() }
            }
            if !agent.localAI.isReady { MarginAISetupStatus(config: config, setup: agent.localAI) }
            if !agent.savedTasks.isEmpty {
                Menu("Saved tasks (\(agent.savedTasks.count))") {
                    ForEach(agent.savedTasks) { task in
                        Button(task.goal + " · " + task.state) { Task { await agent.openSavedTask(task.id) } }
                    }
                }.disabled(agent.isBusy)
            }
            if let task = agent.recoverableTask {
                Text("Saved task: " + task).font(.caption)
                if agent.taskNeedsReconciliation {
                    Text("Check the destination first. Did the interrupted operation complete?").font(.caption)
                    Button("I checked: it completed") { Task { await agent.reconcileTask(wasExecuted: true) } }.disabled(agent.isBusy)
                    Button("I checked: it did not happen") { Task { await agent.reconcileTask(wasExecuted: false) } }.disabled(agent.isBusy)
                } else {
                    Button("Review and resume") { Task { await agent.resumeTask() } }.disabled(agent.isBusy)
                }
            }
            if let problem = agent.problem { problemPage(problem) }
            if !ribbon.isEmpty { ribbonPage }
            if agent.turns.isEmpty && agent.problem == nil && agent.localAI.isReady { blankPage }
            ForEach(agent.turns) { turn in
                turnPage(turn).id(turn.id)
            }
            if let activity = agent.activity {
                workingLine(activity)
                Button("Stop after current step") { agent.cancelRequest() }.buttonStyle(.plain).font(.caption)
            }
            MarginJobProgressView(store: agent.jobs)
            if !agent.ticks.isEmpty { todaysPage }
            if let gameHint, !agent.isBusy, input.isEmpty, !config.banded, config.proactivity != .quiet {
                HStack(alignment: .firstTextBaseline) {
                    Button(gameHint) { self.gameHint = nil; onGames() }.buttonStyle(.plain)
                    Spacer(minLength: 4)
                    Button { self.gameHint = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss puzzle hint")
                }.font(.system(size: 11, design: .serif)).foregroundStyle(MarginTheme.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                pageStack
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
            .onChange(of: agent.turns.count) { _, _ in
                // Land on the TOP of the newest page. A written answer is read from its
                // first line; scrolling to the bottom hid both the question and the
                // kicker behind the fold.
                // Land on the QUESTION, so the exchange reads from its first line. The
                // newest turn is the answer; scrolling there hides what was asked.
                let target = agent.turns.last(where: { $0.role == .user }) ?? agent.turns.last
                if let target { withAnimation { proxy.scrollTo(target.id, anchor: .top) } }
            }
        }
    }

    // MARK: Type

    /// Fix 6: the kicker. One style for the date, the duration and every day header, so a
    /// page never has two competing titles.
    private func kicker(_ text: String, color: Color = MarginTheme.inkSoft) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold, design: .serif))
            .tracking(1.2)
            .foregroundStyle(color)
    }

    private func body(_ text: String, color: Color = MarginTheme.ink) -> some View {
        Text(text)
            .font(.system(size: 13.5, design: .serif))
            .lineSpacing(Self.rulePitch - 16)   // fix 8: ink on the rule
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pages

    /// Fix 3: the date is the page's kicker, not a title bar sitting on the paper. Fix 7:
    /// the empty ruled lines are correct *here* — this is the page you're about to write
    /// on — and nowhere else.
    private var blankPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
            ForEach(suggestions, id: \.self) { line in
                Button {
                    input = line
                    Task { await ask() }
                } label: { body(line, color: MarginTheme.inkSoft) }
                .buttonStyle(.plain)
            }
            // Half the registry is file tools, and they can't see anything until a folder
            // is granted. Saying so on the first page is the difference between "it can't
            // do files" and "it hasn't been allowed to yet".
            if let roots, roots.roots.isEmpty {
                Divider().overlay(MarginTheme.rule).padding(.vertical, 2)
                Text("I can't see any of your files yet.")
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
                Button("Grant a folder…") { roots.grant() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold, design: .serif))
                    .foregroundStyle(MarginTheme.cloth)
            }
        }
    }

    /// What it can do, shown as things you can actually press. Drawn from **both halves**
    /// of the registry — a calendar-only list was quietly telling people files weren't
    /// supported. The file examples only appear once a folder is granted, because
    /// suggesting something that will answer "not granted" is a worse first impression
    /// than not suggesting it.
    private var suggestions: [String] {
        var lines = ["What's on today?", "When am I free for 30 minutes?"]
        if let roots, !roots.roots.isEmpty {
            let folder = roots.roots[0].name
            lines.append("What's in my \(folder) folder?")
            lines.append("Find the PDFs in \(folder)")
        }
        lines.append("Lunch with Sam tomorrow 1pm")
        return lines
    }

    /// What it is doing, on the line the answer will appear on. The elapsed count starts
    /// at 5 seconds — early enough that a slow local model reads as slow rather than
    /// broken, late enough that a quick answer never shows a stopwatch.
    @ViewBuilder private func workingLine(_ activity: String) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = agent.activitySince.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 6) {
                Text(elapsed >= 15 && activity.hasPrefix("Reading your request:") ? "Still waiting for the model to interpret your request. No action has been taken." : activity)
                    .font(.system(size: 12.5, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if elapsed >= 5 {
                    Text("\(Int(elapsed))s")
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft.opacity(0.7))
                        .monospacedDigit()
                }
                Button("Cancel") { agent.cancelRequest() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(MarginTheme.cloth)
            }
        }
    }

    private func problemPage(_ problem: String) -> some View {
        body(problem, color: MarginTheme.amberInk)
    }

    private var ribbonPage: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1).fill(MarginTheme.ribbonAmber).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ribbon) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        kicker(item.kicker, color: MarginTheme.amberInk)
                        body(item.body)
                    }
                }
            }
        }
    }

    @ViewBuilder private func turnPage(_ turn: AssistantTurn) -> some View {
        if turn.role == .user {
            if turn.text.count > 350 && !expandedRequests.contains(turn.id) {
                Button {
                    expandedRequests.insert(turn.id)
                } label: {
                    Text(DatedEventList.dateCount(turn.text) > 1 ? "Prepare \(DatedEventList.dateCount(turn.text)) dated events · show request" : String(turn.text.prefix(110)) + "… · show request")
                        .font(.system(size: 12, design: .serif)).foregroundStyle(MarginTheme.inkSoft)
                }.buttonStyle(.plain)
            } else {
            Text(turn.text)
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !turn.text.isEmpty { body(turn.text) }
                if let action = turn.action { actionPage(turn, action) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func actionPage(_ turn: AssistantTurn, _ action: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            kicker(action.title)

            ForEach(action.details, id: \.self) { detail in body(detail, color: MarginTheme.inkSoft) }

            // Fix 5 + fix 2: grouped under day headers, ranked, and selectable.
            ForEach(action.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    kicker(group.label)
                        .padding(.top, 2)
                    Rectangle().fill(MarginTheme.rule).frame(height: 0.5)
                    ForEach(group.choices) { choice in
                        choiceRow(turn, choice, enabled: turn.outcome == nil)
                    }
                }
            }

            ForEach(action.assumptions + action.warnings, id: \.self) { note in
                body(note, color: MarginTheme.amberInk)
            }

            // Fix 4: the evidence, under a dashed rule.
            if let provenance = action.provenance {
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 0.6, dash: [2.5, 2.5]))
                        .foregroundStyle(MarginTheme.rule)
                        .frame(height: 0.6)
                    Text(provenance)
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            ForEach(action.sources) { source in
                Link("[\(source.id)] \(source.title)", destination: source.url)
                    .font(.system(size: 11)).foregroundStyle(MarginTheme.cloth)
            }
            actions(turn, action)
        }
    }

    /// A 44pt selectable row with a tick, one pre-selected as the recommendation.
    private func choiceRow(_ turn: AssistantTurn, _ choice: PageChoice, enabled: Bool) -> some View {
        let picked = turn.action?.multipleSelection == true ? (turn.picked ?? "").split(separator: ",").contains(Substring(choice.id)) : turn.picked == choice.id
        return Button {
            agent.pick(turn.id, choice: choice.id)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(picked ? MarginTheme.cloth : Color.clear)
                        .overlay(Circle().stroke(picked ? Color.clear : MarginTheme.ink.opacity(0.26), lineWidth: 1.5))
                    if picked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(MarginTheme.paper)
                    }
                }
                .frame(width: 17, height: 17)

                VStack(alignment: .leading, spacing: 4) {
                Text(choice.label)
                    .font(.system(size: 13.5, weight: picked || choice.tone == .best ? .semibold : .regular, design: .serif))
                    .foregroundStyle(choice.tone == .caution ? MarginTheme.inkSoft : MarginTheme.ink)
                    // File names are long and their **end** is the informative part — the
                    // extension, the date, the version. Tail truncation hid exactly that,
                    // so long names truncate in the middle instead.
                    .lineLimit(turn.action?.multipleSelection == true ? nil : 2)
                    .truncationMode(.middle)
                    if turn.action?.multipleSelection == true, let note = choice.note {
                        Text(note).font(.system(size: 11, design: .serif)).foregroundStyle(MarginTheme.inkSoft)
                    }
                }
                Spacer(minLength: 6)
                if turn.action?.multipleSelection != true, let note = choice.note {
                    Text(note)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(choice.tone == .caution ? MarginTheme.amberInk : MarginTheme.inkSoft)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(-1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(picked ? MarginTheme.cloth.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(picked ? MarginTheme.cloth.opacity(0.34) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// At most two. Fix 9: the primary shows its key.
    @ViewBuilder private func actions(_ turn: AssistantTurn, _ action: ProposedAction) -> some View {
        if let outcome = turn.outcome {
            HStack(spacing: 8) {
                Text(outcome)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
                    .strikethrough(turn.undone)
                if action.undo != nil, !turn.undone, !outcome.hasPrefix("Couldn't") {
                    Button("Back to the ribbon") { Task { await agent.undo(turn.id) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(MarginTheme.cloth)
                }
            }
        } else if action.kind == .change || !action.groups.isEmpty || !action.agentReadable {
            HStack(spacing: 8) {
                Button {
                    Task { await agent.confirm(turn.id) }
                } label: {
                    HStack(spacing: 5) {
                        Text(action.multipleSelection ? "\(action.confirmLabel) \((turn.picked ?? "").split(separator: ",").count) events" : (action.tearOut ? "Tear out & send" : action.confirmLabel))
                        Text("⏎").opacity(0.7)
                    }
                }
                .buttonStyle(TearOutButton())
                .disabled(action.multipleSelection && (turn.picked ?? "").isEmpty)
                if let secondary = action.secondary {
                    Button(secondary.label) { Task { await agent.runSecondary(turn.id) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                } else {
                    Button("Leave it") { agent.dismissProposal(turn.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                }
            }
            .padding(.top, 2)
        }
    }

    private var todaysPage: some View {
        VStack(alignment: .leading, spacing: 4) {
            kicker("Handled today")
            ForEach(agent.ticks) { tick in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("✓").font(.system(size: 10, design: .serif)).foregroundStyle(MarginTheme.cloth)
                    Text(tick.text)
                        .font(.system(size: 11.5, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                        .strikethrough(tick.crossed)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if tick.crossable {
                        Button("cross out") { Task { await agent.crossOut(tick.id) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, design: .serif))
                            .foregroundStyle(MarginTheme.cloth)
                    }
                }
            }
            Text("Crossable for an hour.")
                .font(.system(size: 9.5, design: .serif))
                .foregroundStyle(MarginTheme.inkSoft.opacity(0.8))
        }
    }

    /// Fix 9: the pencil stays, and so does the key hint.
    private var writingLine: some View {
        HStack(spacing: 8) {
            Button { if images.active { images.choose() } else { images.active = true } } label: {
                Image(systemName: "photo.badge.plus").font(.system(size: 14))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(MarginTheme.cloth)
                .help("Attach an image")
                .accessibilityLabel("Attach an image")
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundStyle(MarginTheme.inkSoft.opacity(0.8))
            TextField("", text: $input,
                      prompt: Text(images.active ? "Ask about this image…" : agent.turns.isEmpty ? "Write here…" : "Ask for a change…")
                        .foregroundColor(MarginTheme.inkSoft))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .disabled(agent.isThinking || (!images.active && !agent.localAI.isReady))
                .focused($writing)
                .onSubmit { Task { await ask() } }
            Text("esc")
                .font(.system(size: 9, design: .serif))
                .foregroundStyle(MarginTheme.inkSoft.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// Ruled lines, drawn at the pitch the text is set on. Only visible where the page is
    /// waiting to be written on.
    private var paper: some View {
        ZStack {
            MarginTheme.paper
            if agent.turns.isEmpty {
                GeometryReader { geo in
                    Path { path in
                        var y: CGFloat = Self.rulePitch + 12
                        while y < geo.size.height {
                            path.move(to: CGPoint(x: 10, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width - 12, y: y))
                            y += Self.rulePitch
                        }
                    }
                    .stroke(MarginTheme.rule.opacity(0.5), lineWidth: 0.5)
                }
            }
        }
    }

    private func ask() async {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "a little diversion" {
            input = ""; onGames(); return
        }
        guard images.active || agent.localAI.isReady else { return }
        let text = input
        input = ""
        await agent.send(text)
        // If the engine disappeared after the readiness check, keep the unsent request.
        if !images.active && !agent.localAI.isReady && input.isEmpty { input = text }
    }
}

/// The send button, which on a notebook is a page leaving the pad.
private struct TearOutButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold, design: .serif))
            .foregroundStyle(MarginTheme.paper)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(MarginTheme.cloth.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}


/// A local diversion: no agent calls, permissions, telemetry or external state.
@MainActor final class MarginPocketGames: ObservableObject {
    enum Game: String, CaseIterable { case fifteen = "Fifteen", pairs = "Pairs" }
    struct Progress: Codable {
        var board: [Int]
        var start: [Int]
        var moves = 0
        var level = 1
        var matched: Set<Int> = []
    }
    @Published private(set) var game: Game
    @Published private var progress: [String: Progress]
    @Published private(set) var revealed: [Int] = []
    private let defaults: UserDefaults
    private var generation = 0
    private static let key = "margin_pocket_games_v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        game = Game(rawValue: defaults.string(forKey: Self.key + "_selected") ?? "") ?? .fifteen
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Progress].self, from: $0) } ?? [:]
        progress = saved.filter { key, value in
            guard value.level > 0, value.level <= 1_000_000, value.moves >= 0, value.board.count == value.start.count,
                  value.matched.allSatisfy({ value.board.indices.contains($0) }) else { return false }
            if key == Game.fifteen.rawValue { return value.board.sorted() == Array(0...15) && value.start.sorted() == Array(0...15) }
            let counts = Dictionary(grouping: value.board, by: { $0 })
            return key == Game.pairs.rawValue && value.board.count >= 12 && value.board.count <= 24 && value.board.count % 2 == 0 && counts.allSatisfy { $0.key >= 0 && $0.key < 12 && $0.value.count == 2 } && value.start.sorted() == value.board.sorted()
        }
        for kind in Game.allCases where progress[kind.rawValue] == nil { progress[kind.rawValue] = Self.make(kind, level: 1) }
        save()
    }
    static func adjacent(_ a: Int, _ b: Int) -> Bool { abs(a / 4 - b / 4) + abs(a % 4 - b % 4) == 1 }
    private var current: Progress { progress[game.rawValue]! }
    var board: [Int] { current.board }
    var moves: Int { current.moves }
    var level: Int { current.level }
    var matched: Set<Int> { current.matched }
    var won: Bool { game == .fifteen ? board == Array(1...15) + [0] : matched.count == board.count }
    private func save() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.key) }
        defaults.set(game.rawValue, forKey: Self.key + "_selected")
    }
    private static func make(_ kind: Game, level: Int) -> Progress {
        var board: [Int]
        if kind == .pairs {
            let count = min(6 + (level - 1) / 3 * 2, 12)
            board = (Array(0..<count) + Array(0..<count)).shuffled()
        } else {
            board = Array(1...15) + [0]
            var previous = -1
            for _ in 0..<min(8 + (level - 1) * 8, 160) {
                let blank = board.firstIndex(of: 0)!
                let next = board.indices.filter { Self.adjacent($0, blank) && $0 != previous }.randomElement()!
                board.swapAt(blank, next); previous = blank
            }
            if board == Array(1...15) + [0] { board.swapAt(14, 15) }
        }
        return Progress(board: board, start: board, level: level)
    }
    func select(_ kind: Game) { generation += 1; revealed = []; game = kind; save() }
    func restart() {
        generation += 1; revealed = []
        progress[game.rawValue] = Progress(board: current.start, start: current.start, level: level)
        save()
    }
    func nextLevel() {
        guard won else { return }
        let old = current.start
        var next = Self.make(game, level: min(level + 1, 1_000_000))
        while next.start == old { next = Self.make(game, level: next.level) }
        generation += 1; revealed = []; progress[game.rawValue] = next; save()
    }
    func play(_ index: Int) {
        guard board.indices.contains(index), !won else { return }
        var value = current
        if game == .fifteen {
            let blank = board.firstIndex(of: 0)!
            guard Self.adjacent(index, blank) else { return }
            value.board.swapAt(index, blank); value.moves += 1
        } else {
            guard revealed.count < 2, !revealed.contains(index), !matched.contains(index) else { return }
            revealed.append(index)
            guard revealed.count == 2 else { return }
            value.moves += 1
            if board[revealed[0]] == board[revealed[1]] {
                value.matched.formUnion(revealed); revealed = []
            } else {
                let version = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    guard let self, self.generation == version else { return }
                    self.revealed = []
                }
            }
        }
        progress[game.rawValue] = value; save()
    }
    func discover() { defaults.set(true, forKey: Self.key + "_discovered") }
    func claimHint(now: Date = Date()) -> String? {
        guard !defaults.bool(forKey: Self.key + "_discovered") else { return nil }
        let count = defaults.integer(forKey: Self.key + "_hint_count")
        let last = defaults.object(forKey: Self.key + "_last_hint") as? Date ?? .distantPast
        guard count < 3, now.timeIntervalSince(last) >= 36 * 3600 else { return nil }
        defaults.set(count + 1, forKey: Self.key + "_hint_count"); defaults.set(now, forKey: Self.key + "_last_hint")
        return ["A little puzzle, if you fancy a pause.", "There’s a little diversion tucked in the spine.", "Some pages are just for play."][count]
    }
}

struct MarginGamesPage: View {
    @ObservedObject var games: MarginPocketGames
    let done: () -> Void
    private let symbols = ["☀", "☾", "✿", "♧", "◇", "☆", "♬", "☂", "⚓", "⚑", "✦", "♡"]
    var body: some View {
        HStack(spacing: 0) {
            MarginTheme.cloth.frame(width: 11)
            VStack(alignment: .leading, spacing: 15) {
                Button("← Back to notebook", action: done).buttonStyle(.plain).font(.caption)
                Text("A little diversion.").font(.system(size: 22, design: .serif))
                Text("Level \(games.level) · progress saved").font(.caption).foregroundStyle(MarginTheme.inkSoft)
                Picker("Game", selection: Binding(get: { games.game }, set: { games.select($0) })) {
                    ForEach(MarginPocketGames.Game.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text(games.game == .fifteen ? "Arrange 1–15. Click a tile beside the space." : "Turn over two cards. Find \(games.board.count / 2) matching pairs.")
                    .font(.system(size: 12, design: .serif)).frame(height: 32, alignment: .leading)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(games.board.indices, id: \.self) { index in
                        let visible = games.revealed.contains(index) || games.matched.contains(index)
                        let label = games.game == .fifteen ? (games.board[index] == 0 ? "" : String(games.board[index])) : (visible ? symbols[games.board[index]] : "·")
                        Button { games.play(index) } label: {
                            Text(label).font(.system(size: 25, design: .serif))
                                .frame(maxWidth: .infinity).frame(height: 49)
                                .background(MarginTheme.cloth.opacity(games.matched.contains(index) ? 0.22 : 0.08), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                            .disabled(games.game == .fifteen ? games.board[index] == 0 : games.matched.contains(index))
                            .accessibilityLabel(games.game == .fifteen ? "Tile \(games.board[index])" : "Card \(index + 1), \(visible ? label : "face down")")
                    }
                }
                Text(games.won ? "Everything in its place. Nicely done." : "\(games.moves) \(games.game == .fifteen ? "moves" : "turns")")
                    .font(.caption).accessibilityAddTraits(.updatesFrequently)
                HStack {
                    Text("Leave whenever you like.").font(.caption)
                    Spacer()
                    if games.won { Button("Next level") { games.nextLevel() } }
                    else { Button("Start over") { games.restart() } }
                }
                Spacer(minLength: 0)
            }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MarginTheme.paper)
        }.foregroundStyle(MarginTheme.ink).environment(\.colorScheme, .light)
            .clipShape(.rect(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 9, topTrailingRadius: 9))
            .onExitCommand(perform: done)
    }
}

extension MarginHistory.RibbonColor {
    var ink: Color {
        switch self {
        case .red: Color(red: 0.76, green: 0.22, blue: 0.17)
        case .gold: Color(red: 0.73, green: 0.56, blue: 0.12)
        case .green: Color(red: 0.16, green: 0.37, blue: 0.27)
        case .purple: Color(red: 0.35, green: 0.29, blue: 0.66)
        case .orange: Color(red: 0.90, green: 0.43, blue: 0.12)
        case .teal: Color(red: 0.08, green: 0.51, blue: 0.47)
        case .blue: Color(red: 0.16, green: 0.40, blue: 0.78)
        case .pink: Color(red: 0.82, green: 0.34, blue: 0.57)
        case .lime: Color(red: 0.52, green: 0.64, blue: 0.16)
        case .cyan: Color(red: 0.20, green: 0.68, blue: 0.80)
        case .brown: Color(red: 0.48, green: 0.31, blue: 0.21)
        case .slate: Color(red: 0.36, green: 0.41, blue: 0.47)
        }
    }
}

struct MarginSavedRibbons: View {
    @ObservedObject var history: MarginHistory
    @ObservedObject var agent: MarginAgent
    let imageRequest: String
    let openSavedIndex: () -> Void
    let closeIndex: () -> Void
    @State private var editing: UUID?
    @State private var title = ""
    @State private var color: MarginHistory.RibbonColor = .red
    private var nextColor: MarginHistory.RibbonColor {
        MarginHistory.RibbonColor.allCases[history.bookmarks.count % MarginHistory.RibbonColor.allCases.count]
    }
    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(history.bookmarks.prefix(5))) { entry in
                Button {
                    agent.openConversation(entry); closeIndex()
                } label: {
                    RoundedRectangle(cornerRadius: 5).fill((entry.bookmark?.color ?? .red).ink.gradient)
                        .frame(width: 27, height: 31)
                        .overlay { if agent.currentPageID == entry.id { Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(.white) } }
                }.buttonStyle(.plain).disabled(agent.isBusy)
                    .help("\(entry.displayTitle) — \(entry.summary)")
                    .accessibilityLabel("\(entry.bookmark?.color.rawValue ?? "") ribbon: \(entry.displayTitle). \(entry.summary)")
                    .contextMenu {
                        Button("Edit title and colour…") { title = entry.displayTitle; color = entry.bookmark?.color ?? .red; editing = entry.id }
                        ForEach(MarginHistory.RibbonColor.allCases) { choice in
                            Button(choice.rawValue.capitalized) { history.mark(entry.id, color: choice) }
                        }
                        Button("Move to first") { if let first = history.bookmarks.first { history.moveBookmark(entry.id, before: first.id) } }
                        Button("Remove ribbon") { history.unmark(entry.id) }
                    }
                    .onDrag { NSItemProvider(object: entry.id.uuidString as NSString) }
                    .onDrop(of: ["public.text"], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
                            Task { @MainActor in history.moveBookmark(id, before: entry.id) }
                        }
                        return true
                    }
            }
            Button { agent.bookmarkCurrentPage(color: nextColor, imageRequest: imageRequest) } label: {
                Image(systemName: "plus").font(.system(size: 13)).frame(width: 27, height: 29)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(MarginTheme.inkSoft.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3])))
            }.buttonStyle(.plain).disabled(agent.isBusy || agent.currentPageID == nil)
                .help("Save this page. Right-click to choose a ribbon colour.")
                .accessibilityLabel("Save this page")
                .contextMenu {
                    ForEach(MarginHistory.RibbonColor.allCases) { choice in
                        Button("Save with \(choice.rawValue) ribbon") { agent.bookmarkCurrentPage(color: choice, imageRequest: imageRequest) }
                    }
                }
                .onDrag { NSItemProvider(object: "margin-save-current" as NSString) }
            if history.bookmarks.count > 5 {
                Button("+\(history.bookmarks.count - 5)", action: openSavedIndex)
                    .font(.system(size: 10)).buttonStyle(.plain).help("All saved pages")
            }
            Spacer(minLength: 0)
        }.frame(width: 31).padding(.top, 39)
            .popover(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved page").font(.headline)
                    TextField("Page title", text: $title)
                    Picker("Ribbon colour", selection: $color) {
                        ForEach(MarginHistory.RibbonColor.allCases) { choice in Text(choice.rawValue.capitalized).tag(choice) }
                    }
                    HStack {
                        Button("Cancel") { editing = nil }
                        Spacer()
                        Button("Save") { if let id = editing { history.mark(id, color: color, title: title) }; editing = nil }
                    }
                }.padding(16).frame(width: 250)
            }
    }
}

// MARK: - Image interaction prototype (no inference or writes)

@MainActor
final class MarginImageDraft: ObservableObject {
    struct Attachment: Identifiable {
        let id = UUID()
        let name: String
        let image: NSImage
        let source: Data
    }
    static let dropTypes = ["public.file-url", "public.png", "public.jpeg", "public.heic", "public.tiff"]
    @Published var pageID = UUID()
    @Published var saved = false
    @Published var kept = false
    @Published var active = false
    @Published var attachments: [Attachment] = []
    @Published var documentMode = false
    @Published var documentText = "" { didSet { if documentText != oldValue { saved = false } } }
    @Published var documentFormat: MarginDocumentExport.Format = .txt {
        didSet {
            if documentMode, documentFormat != oldValue {
                exportFilename = (exportFilename as NSString).deletingPathExtension + "." + documentFormat.rawValue
                saved = false
            }
        }
    }
    func beginDocument(text: String) {
        documentMode = true; documentText = text; documentFormat = .txt
        exportFilename = "extracted-document.txt"; showExport = true; exported = nil; problem = nil
    }
    @Published var showExport = false
    @Published var exportFilename = ""
    @Published var exportFolder: URL?
    @Published var exported: MarginImageExport.Saved?
    var currentExtension: String? {
        guard let current, let source = CGImageSourceCreateWithData(current.source as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return UTType(type as String)?.preferredFilenameExtension
    }
    func beginExport(suggestion: String = "image") {
        guard let ext = currentExtension else { problem = "This image format cannot be saved yet."; return }
        let stem = suggestion.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        exportFilename = String((stem.isEmpty ? "image" : stem).prefix(80)) + "." + ext
        documentMode = false; showExport = true; exported = nil; problem = nil
    }
    func clearExport() { documentMode = false; documentText = ""; documentFormat = .txt; showExport = false; exportFilename = ""; exportFolder = nil; exported = nil }
    @Published var answer = ""
    @Published var readingStatus = "Reading the image…"
    @Published var selected = 0 { didSet { if selected != oldValue { answer = ""; savedRequest = ""; clearExport() } } }
    @Published var problem: String?
    @Published var scenario = "None"
    @Published var previewState = "Review"
    @Published var fields: [String] = [] { didSet { if fields != oldValue { saved = false } } }
    @Published var inspected = false
    private var generation = UUID()
    var current: Attachment? { attachments.indices.contains(selected) ? attachments[selected] : nil }

    func reset() {
        clearExport(); answer = ""; generation = UUID(); pageID = UUID(); saved = false; kept = false; savedRequest = ""; attachments = []; selected = 0; problem = nil
        scenario = "None"; fields = []; inspected = false; active = false
    }
    func importURLs(_ urls: [URL]) {
        active = true; problem = nil
        guard attachments.count + urls.count <= 5 else { problem = "Up to five images fit in this preview. Remove one before adding more."; return }
        for url in urls {
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 25_000_000 else {
                    problem = "\(url.lastPathComponent): choose an image smaller than 25 MB."; continue
                }
                accept(try Data(contentsOf: url), name: url.lastPathComponent)
            } catch { problem = "Could not open \(url.lastPathComponent). Your existing images are still here." }
        }
    }
    func accept(_ data: Data, name: String) {
        guard attachments.count < 5 else { problem = "Up to five images fit in this preview."; return }
        guard data.count <= 25_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 50_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else {
            problem = "\(name) could not be read as an image. This preview accepts images up to 25 MB and 50 megapixels."; return
        }
        clearExport(); answer = ""
        attachments.append(Attachment(name: name, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), source: data))
        saved = false
        selected = attachments.count - 1; scenario = "None"; fields = []; previewState = "Review"
    }
    func receive(_ providers: [NSItemProvider]) -> Bool {
        active = true; problem = nil
        guard attachments.count + providers.count <= 5 else { problem = "Drop no more than five images in total."; return true }
        let token = generation
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, _ in
                    let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        guard self.generation == token else { return }
                        if let url { self.importURLs([url]) } else { self.problem = "This image could not be imported. Try Choose image." }
                    }
                }
            } else if let type = Self.dropTypes.dropFirst().first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                let suggestedName = provider.suggestedName ?? "Imported image"
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    Task { @MainActor in
                        guard self.generation == token else { return }
                        if let data { self.accept(data, name: suggestedName) }
                        else { self.problem = "This image could not be imported. Try Choose image." }
                    }
                }
            } else { problem = "Choose a PNG, JPEG, HEIC or TIFF image." }
        }
        return true
    }
    func choose() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        picker.allowsMultipleSelection = true; picker.canChooseDirectories = false
        if picker.runModal() == .OK { importURLs(picker.urls) }
    }
    static var canPasteImage: Bool {
        let board = NSPasteboard.general
        if board.availableType(from: [.png, .tiff]) != nil { return true }
        if let text = board.string(forType: .fileURL), let url = URL(string: text) {
            return ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(url.pathExtension.lowercased())
        }
        return false
    }
    func paste() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty { importURLs(urls); return }
        if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff) {
            active = true; accept(data, name: "Pasted image")
        } else { active = true; problem = "The clipboard has no supported image. Text stays in the writing line." }
    }
    struct Snapshot: Codable {
        struct Item: Codable { let name: String; let source: Data }
        let version: Int
        let id: UUID
        let items: [Item]
        let scenario: String
        let fields: [String]
        let request: String
        var answer: String? = nil
        var selectedIndex: Int? = nil
        var documentText: String? = nil
        var documentFormat: MarginDocumentExport.Format? = nil
        var exportFilename: String? = nil
    }
    @Published var savedRequest = ""
    func encoded(request: String) throws -> Data {
        guard request.count <= 8000, fields.allSatisfy({ $0.count <= 2000 }) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try JSONEncoder().encode(Snapshot(version: 1, id: pageID, items: attachments.map { .init(name: $0.name, source: $0.source) }, scenario: scenario, fields: fields, request: request, answer: answer, selectedIndex: selected, documentText: documentMode ? documentText : nil, documentFormat: documentMode ? documentFormat : nil, exportFilename: documentMode ? exportFilename : nil))
    }
    func restore(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, !snapshot.items.isEmpty, snapshot.items.count <= 5,
              snapshot.fields.count <= 20, snapshot.fields.allSatisfy({ $0.count <= 2000 }),
              ["None", "Diagram", "Holidays"].contains(snapshot.scenario),
              (snapshot.scenario != "Diagram" || snapshot.fields.count == 3),
              (snapshot.scenario != "Holidays" || snapshot.fields.count == 8) else { throw CocoaError(.fileReadCorruptFile) }
        // Decode to a temporary store so a bad attachment never destroys the current draft.
        let candidate = MarginImageDraft()
        for item in snapshot.items { candidate.accept(item.source, name: item.name) }
        guard candidate.attachments.count == snapshot.items.count, candidate.problem == nil else { throw CocoaError(.fileReadCorruptFile) }
        clearExport(); generation = UUID(); attachments = candidate.attachments; selected = min(max(snapshot.selectedIndex ?? 0, 0), attachments.count - 1)
        pageID = snapshot.id; scenario = snapshot.scenario; fields = snapshot.fields
        if let text = snapshot.documentText {
            guard text.utf8.count <= 200_000 else { throw CocoaError(.fileReadCorruptFile) }
            beginDocument(text: text); documentFormat = snapshot.documentFormat ?? .txt
            exportFilename = snapshot.exportFilename ?? "extracted-document." + documentFormat.rawValue
        }
        answer = snapshot.answer ?? ""
        savedRequest = snapshot.request; previewState = "Review"; inspected = false; active = true; saved = true; kept = true; problem = nil
    }
    func sample(_ name: String) {
        guard let url = Bundle.main.url(forResource: name == "Diagram" ? "MarginImageDiagram" : "MarginImageEvents", withExtension: "png") else { problem = "The example image is unavailable."; return }
        reset(); importURLs([url]); scenario = name
        if name == "Diagram" { fields = ["Order processing", "order-processing-diagram.png", "Choose a folder in the live version"] }
        else { fields = ["2026-10-12 · Columbus Day / Indigenous Peoples’ Day", "2026-10-31 · Halloween", "2026-11-11 · Veterans Day", "2026-11-26 · Thanksgiving Day", "2026-11-27 · Black Friday", "2026-12-24 · Christmas Eve", "2026-12-25 · Christmas Day", "2026-12-31 · New Year’s Eve"] }
    }
}

struct MarginImagePreviewPage: View {
    @ObservedObject var draft: MarginImageDraft
    let request: String
    var cancelReading: () -> Void = {}
    var chooseDestination: () -> Void = {}
    var saveExport: () -> Void = {}
    var undoExport: () -> Void = {}
    var conversation: AnyView = AnyView(EmptyView())
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var zoom: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !(draft.savedRequest.isEmpty ? request : draft.savedRequest).isEmpty { Text(draft.savedRequest.isEmpty ? request : draft.savedRequest).font(.system(size: 14, weight: .semibold)) }
                Text(draft.scenario == "None" ? "IMAGE" : "\(draft.scenario.uppercased()) · DESIGN SAMPLE")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                if let current = draft.current {
                    if draft.attachments.count > 1 {
                        Picker("Image", selection: $draft.selected) {
                            ForEach(Array(draft.attachments.enumerated()), id: \.element.id) { i, item in Text("\(i + 1) · \(item.name)").tag(i) }
                        }.labelsHidden()
                    }
                    Button { draft.inspected.toggle() } label: {
                        Image(nsImage: current.image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 155)
                            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 5))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 3)
                            .rotationEffect(.degrees(reduceMotion ? 0 : -1))
                            .overlay(alignment: .leading) {
                                if draft.previewState == "Reading" {
                                    Rectangle().fill(MarginTheme.cloth.opacity(0.4)).frame(width: 2)
                                        .offset(x: sweep ? 245 : 0).animation(reduceMotion ? nil : .linear(duration: 1.5), value: sweep)
                                }
                            }
                    }.buttonStyle(.plain)
                        .accessibilityRepresentation {
                            Button("Inspect source image: \(current.name)") { draft.inspected.toggle() }
                        }
                        .help("Inspect source image: \(current.name)")
                        .frame(minHeight: 44)
                    .contextMenu {
                        Button("Save image as…") { draft.beginExport() }
                        Button("Add image…") { draft.choose() }
                        Button("Remove this image") {
                            draft.attachments.remove(at: draft.selected); draft.selected = 0
                            draft.fields = []; draft.clearExport(); draft.answer = ""; draft.scenario = "None"; draft.saved = false
                        }
                    }
                    Text(current.name).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                    if draft.inspected {
                        Text("Source inspection · unrotated").font(.caption.bold())
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: current.image).resizable().scaledToFit().frame(width: 250 * zoom)
                        }.frame(height: 260).background(.white)
                        Slider(value: $zoom, in: 1...5) { Text("Image zoom") }.accessibilityLabel("Image zoom")
                        Button("Close inspection") { draft.inspected = false }.frame(minHeight: 44)
                    }
                    if draft.previewState == "Reading" {
                        Text(draft.readingStatus).font(.subheadline)
                        Button("Cancel") { cancelReading() }.frame(minHeight: 44)
                    } else if let saved = draft.exported {
                        Text("Saved · \(saved.url.lastPathComponent)")
                        HStack {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved.url]) }
                            Button("Undo save") { undoExport() }
                        }
                    } else if draft.showExport {
                        Text(draft.documentMode ? "Here is the draft. You can edit it before saving." : "Save a copy of this image as")
                        if draft.documentMode {
                            Text("Keep this as text, or use Word or Markdown?").font(.subheadline)
                            HStack(spacing: 12) {
                                ForEach(MarginDocumentExport.Format.allCases, id: \.self) { format in
                                    Button(format.label) { draft.documentFormat = format }
                                        .buttonStyle(.plain)
                                        .fontWeight(draft.documentFormat == format ? .semibold : .regular)
                                        .underline(draft.documentFormat == format)
                                        .accessibilityLabel("Use " + format.label)
                                }
                            }
                            TextEditor(text: $draft.documentText).font(.system(size: 13, design: .serif)).frame(minHeight: 150, maxHeight: 220)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel("Extracted document text")
                            Text("Review the transcription, especially any [unclear] text. Word exports editable text; it does not recreate the screenshot layout.").font(.caption)
                        }
                        TextField("Filename", text: $draft.exportFilename).textFieldStyle(.plain)
                            .font(.body.weight(.medium))
                            .accessibilityLabel("Image filename")
                        HStack(alignment: .firstTextBaseline) {
                            Text("in")
                            Button(draft.exportFolder?.lastPathComponent ?? "choose a folder…") { chooseDestination() }
                                .buttonStyle(.plain).underline()
                        }
                            .lineLimit(2).accessibilityLabel("Choose image destination")
                        Text(draft.documentMode ? "Saves the text shown above. Existing files won't be overwritten." : "Copies the attached image in its current format. Existing files won't be overwritten.").font(.caption)
                        HStack {
                            Button(draft.documentMode ? "Save document" : "Save copy") { saveExport() }.disabled(draft.exportFolder == nil)
                            Button("Leave it") { draft.showExport = false }
                        }
                    } else if !draft.answer.isEmpty {
                        Text(draft.answer).textSelection(.enabled)
                    } else if draft.previewState == "Unreadable" {
                        Text("Example: I can read one field, but two are unclear. Replace the image or correct the fields.")
                    } else if draft.previewState == "Ambiguous" {
                        Text("Example: this could describe an event or an expense. Which did you want?")
                        Text("Nothing has been chosen or created.").font(.caption)
                    } else if !draft.fields.isEmpty {

                        ForEach(draft.fields.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fieldLabel(index)).font(.system(size: 11, weight: .semibold)).foregroundStyle(MarginTheme.inkSoft)
                                TextField("Value", text: $draft.fields[index], axis: .vertical).textFieldStyle(.plain)
                                    .padding(8).background(MarginTheme.cloth.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                                    .accessibilityLabel(fieldLabel(index)).frame(minHeight: 44)
                                if draft.scenario == "Holidays" { Text("All day").font(.caption).foregroundStyle(MarginTheme.inkSoft) }
                            }
                        }
                        HStack {
                            Button(draft.scenario == "Diagram" ? "Save image" : "Add 8 events") { }
                                .disabled(true)
                                .help("Available when image reading and action review are connected")
                            Spacer()
                            Button("Inspect source") { draft.inspected = true }
                        }.padding(.vertical, 6)
                    } else {
                        Text("Your image is pinned. Ask a question about it below.").foregroundStyle(MarginTheme.inkSoft)
                    }
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "arrow.down.to.line").font(.title2)
                        Text("Slip an image onto the page").font(.subheadline.weight(.semibold))
                        Text("Drop here, paste with ⌘V, or use the image icon.").font(.caption)
                        Text("PNG, JPEG, HEIC or TIFF · up to 5 images").font(.caption)
                    }.frame(maxWidth: .infinity).padding(14)
                        .background(MarginTheme.cloth.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MarginTheme.cloth.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                }
                conversation
                if let problem = draft.problem { Text(problem).font(.caption).foregroundStyle(MarginTheme.amberInk) }
                Divider()
                Text(draft.exported != nil ? "Saved locally · attached image unchanged." : draft.scenario == "None"
                     ? (draft.saved ? "Saved locally · no action performed." : "The image stays attached. Actions appear above for review.")
                     : "Sample fields, not model output · no action performed.")
                    .font(.system(size: 11)).foregroundStyle(MarginTheme.inkSoft)
            }.padding(14).font(.system(size: 13)).foregroundStyle(MarginTheme.ink)
        }
        .onChange(of: draft.previewState) { _, value in sweep = false; if value == "Reading" { DispatchQueue.main.async { sweep = true } } }
    }
    private func fieldLabel(_ index: Int) -> String {
        if draft.scenario == "Diagram" { return ["Subject", "Filename · editable suggestion", "Destination · not selected"][index] }
        return "Event \(index + 1) of 8 · date and title"
    }
}
