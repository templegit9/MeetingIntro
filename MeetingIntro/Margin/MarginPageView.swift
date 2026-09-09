import SwiftUI

/// The opened notebook: a dated page you write on, and the pages it writes back.
///
/// Two rules from the spec do the heavy lifting here, and both are about **legibility of
/// state, not decoration**:
/// - a draft sits on a page and is obviously unsent until it is torn out, which no chat
///   bubble can claim;
/// - the ribbon marks the thing waiting for you, and "back to the ribbon" is undo.
struct MarginPageView: View {

    @ObservedObject var agent: MarginAgent
    @ObservedObject var config: MarginConfig
    let onClose: () -> Void

    @State private var input = ""
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider().overlay(MarginTheme.rule)
            content
            Divider().overlay(MarginTheme.rule)
            writingLine
        }
        .frame(width: MarginTheme.openWidth)
        .background(paperBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MarginTheme.clothDark.opacity(0.55), lineWidth: 1)
        )
        // Margin is its own brand: the page is always paper, whatever the host app or the
        // system appearance is doing.
        .environment(\.colorScheme, .light)
        .task {
            writing = true
            await agent.checkAvailability()
        }
        .onExitCommand { onClose() }
    }

    /// Dated at the top like a real page.
    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .foregroundStyle(MarginTheme.inkSoft)
            Spacer()
            if agent.isThinking {
                Text("looking…").font(.system(size: 10, design: .serif)).foregroundStyle(MarginTheme.inkSoft)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MarginTheme.inkSoft)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 7)
    }

    @ViewBuilder private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let problem = agent.problem { problemPage(problem) }
                    if agent.turns.isEmpty && agent.problem == nil { blankPage }
                    ForEach(agent.turns) { turn in
                        turnPage(turn).id(turn.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(maxHeight: 380)
            .onChange(of: agent.turns.count) { _, _ in
                if let last = agent.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    /// Nothing written yet. Ruled lines and a couple of things it can do — the notebook
    /// equivalent of an empty page, rather than a marketing panel.
    private var blankPage: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(["What's on today?", "When am I free for 30 minutes?", "Lunch with Sam tomorrow 1pm"], id: \.self) { line in
                Button {
                    input = line
                    Task { await ask() }
                } label: {
                    Text(line)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func problemPage(_ problem: String) -> some View {
        Text(problem)
            .font(.system(size: 12, design: .serif))
            .foregroundStyle(MarginTheme.amberInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func turnPage(_ turn: AssistantTurn) -> some View {
        if turn.role == .user {
            // What you wrote, in your own hand — indented, no bubble.
            Text(turn.text)
                .font(.system(size: 12.5, weight: .medium, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(.system(size: 12.5, design: .serif))
                        .foregroundStyle(MarginTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = turn.action { actionPage(turn, action) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A written page. Nothing here has happened yet, and it says so by being a page
    /// rather than a message.
    @ViewBuilder private func actionPage(_ turn: AssistantTurn, _ action: ProposedAction) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // The ribbon marks anything still waiting on you.
            RoundedRectangle(cornerRadius: 1)
                .fill(turn.outcome == nil && action.kind == .change ? MarginTheme.ribbonAmber : Color.clear)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(MarginTheme.ink)
                ForEach(action.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(action.assumptions + action.warnings, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(MarginTheme.amberInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let outcome = turn.outcome {
                    HStack(spacing: 8) {
                        Text(outcome)
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(MarginTheme.inkSoft)
                            .strikethrough(turn.undone)
                        if action.undo != nil, !turn.undone, !outcome.hasPrefix("Couldn't"), outcome != "Set aside." {
                            Button("Back to the ribbon") { Task { await agent.undo(turn.id) } }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, design: .serif))
                                .foregroundStyle(MarginTheme.cloth)
                        }
                    }
                } else if action.kind == .change {
                    HStack(spacing: 8) {
                        Button(action.tearOut ? "Tear out & send" : action.confirmLabel) {
                            Task { await agent.confirm(turn.id) }
                        }
                        .buttonStyle(TearOutButton())
                        Button("Leave it") { agent.dismissProposal(turn.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(MarginTheme.inkSoft)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// The line you write on. Enter asks; escape closes.
    private var writingLine: some View {
        HStack(spacing: 8) {
            TextField("", text: $input, prompt: Text("Write here…").foregroundColor(MarginTheme.inkSoft))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .focused($writing)
                .onSubmit { Task { await ask() } }
            Text("⏎ ask · esc close")
                .font(.system(size: 9, design: .serif))
                .foregroundStyle(MarginTheme.inkSoft.opacity(0.7))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    /// Cream, with the faint ruled lines a page has.
    private var paperBackground: some View {
        ZStack {
            MarginTheme.paper
            GeometryReader { geo in
                Path { path in
                    var y: CGFloat = 26
                    while y < geo.size.height {
                        path.move(to: CGPoint(x: 12, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width - 12, y: y))
                        y += 22
                    }
                }
                .stroke(MarginTheme.rule.opacity(0.55), lineWidth: 0.5)
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
            .font(.system(size: 11, weight: .semibold, design: .serif))
            .foregroundStyle(MarginTheme.paper)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(MarginTheme.cloth.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}
