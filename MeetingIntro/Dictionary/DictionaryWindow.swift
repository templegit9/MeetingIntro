import SwiftUI
import AVFoundation

/// The Dictionary plugin window — type a word → meaning, part of speech, examples,
/// synonyms/antonyms (tap to look up), and pronunciation audio.
struct DictionaryWindow: View {
    @State private var query = ""
    @State private var entries: [WordEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var suggestions: [String] = []
    /// When a typo was auto-corrected, the word the user originally typed.
    @State private var correctedFrom: String?
    @State private var recent: [String] = []
    @FocusState private var focused: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Look up a word…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { lookup(query) }
                if loading { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = ""; entries = []; error = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            Divider()
            ScrollView { content.padding(16) }
        }
        .frame(minWidth: 440, minHeight: 440)
        .onAppear { focused = true }
    }

    @ViewBuilder private var content: some View {
        if let error {
            VStack(spacing: 10) {
                Image(systemName: "book.closed").font(.system(size: 34, weight: .thin)).foregroundStyle(.tertiary)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !suggestions.isEmpty {
                    Text("Did you mean:").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { w in chip(w, .accentColor) { lookup(w) } }
                    }
                    .frame(maxWidth: 340)
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 40)
        } else if entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type a word and press return.").foregroundStyle(.secondary)
                if !recent.isEmpty {
                    Text("Recent").font(.caption).foregroundStyle(.tertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(recent, id: \.self) { w in chip(w, .accentColor) { lookup(w) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let from = correctedFrom {
                    (Text("Showing results for ").foregroundStyle(.secondary)
                        + Text(entries.first?.word ?? "").fontWeight(.semibold)
                        + Text(" — you searched “\(from)”").foregroundStyle(.secondary))
                        .font(.caption)
                }
                ForEach(entries) { entryView($0) }
            }
        }
    }

    private func entryView(_ e: WordEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.word).font(.system(.title, weight: .semibold))
                if let p = e.phonetic { Text(p).font(.title3).foregroundStyle(.secondary) }
                if let a = e.audioURL {
                    Button { play(a) } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.borderless)
                }
                Spacer()
            }
            if let note = e.sourceNote { Text(note).font(.caption2).foregroundStyle(.tertiary) }
            ForEach(e.meanings) { m in
                VStack(alignment: .leading, spacing: 6) {
                    if !m.partOfSpeech.isEmpty {
                        Text(m.partOfSpeech).font(.callout.italic().weight(.medium)).foregroundStyle(.purple)
                    }
                    ForEach(Array(m.definitions.enumerated()), id: \.offset) { i, d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i + 1). \(d.text)").fixedSize(horizontal: false, vertical: true)
                            if let ex = d.example {
                                Text("“\(ex)”").font(.callout).italic().foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !m.synonyms.isEmpty { chipRow("Synonyms", m.synonyms, .green) }
                    if !m.antonyms.isEmpty { chipRow("Antonyms", m.antonyms, .orange) }
                }
                .padding(.bottom, 2)
            }
            Divider()
        }
    }

    private func chipRow(_ title: String, _ words: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(words.prefix(24)), id: \.self) { w in chip(w, color) { lookup(w) } }
            }
        }
    }

    private func chip(_ text: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func lookup(_ raw: String) {
        let w = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        query = w
        loading = true
        error = nil
        suggestions = []
        correctedFrom = nil
        focused = false
        Task {
            do {
                let res = try await DictionaryService.lookup(w)
                entries = res
                recordRecent(res.first?.word ?? w)
            } catch {
                // Likely a typo — try the best spelling correction automatically ("did you mean").
                let guesses = DictionaryService.suggestions(for: w)
                if let best = guesses.first, let res = try? await DictionaryService.lookup(best) {
                    entries = res
                    correctedFrom = w
                    query = best
                    suggestions = Array(guesses.dropFirst())
                    recordRecent(res.first?.word ?? best)
                } else {
                    entries = []
                    suggestions = guesses
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            loading = false
        }
    }

    private func recordRecent(_ word: String) {
        recent.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        recent.insert(word, at: 0)
        recent = Array(recent.prefix(12))
    }

    private func play(_ url: URL) {
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// Minimal wrapping layout for chips (macOS 14 `Layout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: maxW == .infinity ? maxX : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
