import SwiftUI

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
    var ribbon: [MarginNudge] = []
    var onWatches: () -> Void = {}
    let onClose: () -> Void
    /// Probe mode: the same stack, laid out unbounded so its true height can be measured.
    /// Fix 7 — the page ends where the answer ends, and a panel can only do that if
    /// something measures the answer first.
    var measuring = false

    @State private var input = ""
    @FocusState private var writing: Bool

    /// Rule pitch. Fix 8: text is laid out on this rhythm, so ink sits *on* the line
    /// instead of floating between lines drawn to a different beat.
    private static let rulePitch: CGFloat = 25

    var body: some View {
        if measuring {
            pageStack.frame(width: MarginTheme.openWidth - 11).padding(.horizontal, 14).padding(.vertical, 14)
        } else {
            page
        }
    }

    /// Height this content needs at the page's real width, plus the writing line.
    @MainActor static func fittingHeight(agent: MarginAgent, config: MarginConfig,
                                         ribbon: [MarginNudge]) -> CGFloat {
        let probe = NSHostingView(rootView: MarginPageView(agent: agent, config: config,
                                                           ribbon: ribbon, onClose: {},
                                                           measuring: true))
        probe.frame = NSRect(x: 0, y: 0, width: MarginTheme.openWidth, height: 2000)
        probe.layoutSubtreeIfNeeded()
        return probe.fittingSize.height + 44
    }

    private var page: some View {
        HStack(spacing: 0) {
            spine
            VStack(alignment: .leading, spacing: 0) {
                content
                Divider().overlay(MarginTheme.rule)
                writingLine
            }
            .background(paper)
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
        .overlay(alignment: .topLeading) { hangingRibbon }
        .environment(\.colorScheme, .light)
        .onAppear { writing = true }
        .task { await agent.checkAvailability() }
        .onExitCommand { onClose() }
    }

    /// Fix 1: the spine. Eleven points of cloth down the bound edge — the whole difference
    /// between a notebook page and a beige dialog.
    private var spine: some View {
        LinearGradient(colors: [MarginTheme.cloth, MarginTheme.clothDark],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 11)
            .contextMenu {
                // Fix 3's other half: the controls that used to sit on the paper.
                Button("What it's watching") { onWatches() }
                Toggle("Band it — won't speak first", isOn: Binding(
                    get: { config.banded }, set: { config.banded = $0 }))
                Divider()
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
            if let problem = agent.problem { problemPage(problem) }
            if !ribbon.isEmpty { ribbonPage }
            if agent.turns.isEmpty && agent.problem == nil { blankPage }
            ForEach(agent.turns) { turn in
                turnPage(turn).id(turn.id)
            }
            if !agent.ticks.isEmpty { todaysPage }
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
            ForEach(["What's on today?", "When am I free for 30 minutes?", "Lunch with Sam tomorrow 1pm"], id: \.self) { line in
                Button {
                    input = line
                    Task { await ask() }
                } label: { body(line, color: MarginTheme.inkSoft) }
                .buttonStyle(.plain)
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
            Text(turn.text)
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

            actions(turn, action)
        }
    }

    /// A 44pt selectable row with a tick, one pre-selected as the recommendation.
    private func choiceRow(_ turn: AssistantTurn, _ choice: PageChoice, enabled: Bool) -> some View {
        let picked = turn.picked == choice.id
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

                Text(choice.label)
                    .font(.system(size: 13.5, weight: picked || choice.tone == .best ? .semibold : .regular, design: .serif))
                    .foregroundStyle(choice.tone == .caution ? MarginTheme.inkSoft : MarginTheme.ink)
                if let note = choice.note {
                    Text(note)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(choice.tone == .caution ? MarginTheme.amberInk : MarginTheme.inkSoft)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
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
        } else if action.kind == .change || !action.groups.isEmpty {
            HStack(spacing: 8) {
                Button {
                    Task { await agent.confirm(turn.id) }
                } label: {
                    HStack(spacing: 5) {
                        Text(action.tearOut ? "Tear out & send" : action.confirmLabel)
                        Text("⏎").opacity(0.7)
                    }
                }
                .buttonStyle(TearOutButton())
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
            Image(systemName: "pencil")
                .font(.system(size: 10))
                .foregroundStyle(MarginTheme.inkSoft.opacity(0.8))
            TextField("", text: $input, prompt: Text("Ask for a change…").foregroundColor(MarginTheme.inkSoft))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(MarginTheme.ink)
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
        let text = input
        input = ""
        await agent.send(text)
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
