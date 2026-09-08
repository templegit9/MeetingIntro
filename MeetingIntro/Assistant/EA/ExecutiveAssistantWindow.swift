import SwiftUI

/// The assistant's surface: a transcript of short turns, each proposal rendered as a
/// card you confirm. Modelled on the Quick Add preview rather than a chat app, because
/// the point is the action, not the conversation.
struct ExecutiveAssistantWindow: View {
    @ObservedObject var assistant: ExecutiveAssistant
    @ObservedObject var config: ExecutiveAssistantConfig

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
        .task {
            inputFocused = true
            await assistant.checkAvailability()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Executive Assistant").font(.headline)
                Text("\(config.model) · on this Mac")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if assistant.isThinking { ProgressView().controlSize(.small) }
            Button {
                assistant.clear()
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Clear the conversation")
                .disabled(assistant.turns.isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let problem = assistant.problem {
                        // Three different problems, three different fixes — never one
                        // shrug. This is the whole reason the client has typed errors.
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if assistant.turns.isEmpty { suggestions }
                    ForEach(assistant.turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: assistant.turns.count) { _, _ in
                if let last = assistant.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try").font(.caption).foregroundStyle(.secondary)
            ForEach(["What's on today?",
                     "When am I free for 30 minutes this week?",
                     "Lunch with Sam tomorrow 1pm",
                     "Remind me to submit the expense report by Friday 5pm"], id: \.self) { example in
                Button(example) { input = example; Task { await run() } }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func turnView(_ turn: AssistantTurn) -> some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !turn.text.isEmpty {
                    Text(turn.text).fixedSize(horizontal: false, vertical: true)
                }
                if let action = turn.action { actionCard(turn, action) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Nothing here has run yet. The card is the gap between what a 4B model produced
    /// and what happens to your calendar.
    @ViewBuilder private func actionCard(_ turn: AssistantTurn, _ action: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(action.title).font(.callout.weight(.semibold))
            ForEach(action.details, id: \.self) { detail in
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(action.assumptions, id: \.self) { assumption in
                Label(assumption, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(action.warnings, id: \.self) { warning in
                Label(warning, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome = turn.outcome {
                HStack(spacing: 8) {
                    Text(outcome).font(.caption).foregroundStyle(.secondary)
                    if action.undo != nil, !turn.undone, outcome.hasPrefix("Couldn't") == false, outcome != "Dismissed." {
                        Button("Undo") { Task { await assistant.undo(turn.id) } }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } else if action.kind == .change {
                HStack(spacing: 8) {
                    Button(action.confirmLabel) { Task { await assistant.confirm(turn.id) } }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { assistant.dismissProposal(turn.id) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    if action.undo == nil {
                        Text("Can't be undone from here")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask for something…", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit { Task { await run() } }
            Button("Send") { Task { await run() } }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isThinking)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func run() async {
        let text = input
        input = ""
        await assistant.send(text)
    }
}
