import AppKit
import SwiftUI

/// The Meeting Notes viewer: recordings list on the left, transcript / notes
/// detail on the right. The markdown sidecar files on disk are the source of
/// truth; this window is a reader + pipeline trigger.
struct MeetingNotesWindow: View {

    @ObservedObject var pipeline: MeetingNotesPipeline
    @ObservedObject var notesConfig: MeetingNotesConfig
    @ObservedObject var recordingConfig: RecordingConfig

    @State private var documents: [RecordingDocument] = []
    @State private var selectedID: String?
    @State private var detailTab: DetailTab = .notes

    enum DetailTab: String, CaseIterable {
        case notes = "Notes"
        case transcript = "Transcript"
    }

    private var selectedDocument: RecordingDocument? {
        documents.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(documents) { doc in
                    row(doc).tag(doc.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .overlay {
                if documents.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "record.circle",
                        description: Text("Enable Auto-Record in Settings → Recording, or recordings you make will appear here.")
                    )
                }
            }
        } detail: {
            if let doc = selectedDocument {
                detailView(doc)
            } else {
                ContentUnavailableView(
                    "Select a recording",
                    systemImage: "doc.text",
                    description: Text("Pick a meeting on the left to read its transcript and notes.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear(perform: refresh)
        // Job-state changes flip sidecar existence — refresh the listing.
        .onChange(of: pipeline.jobs) { _, _ in refresh() }
    }

    private func refresh() {
        documents = RecordingDocument.scan(directory: recordingConfig.resolveSaveDirectory())
        if selectedID == nil { selectedID = documents.first?.id }
    }

    // MARK: - Sidebar row

    @ViewBuilder
    private func row(_ doc: RecordingDocument) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                if let date = doc.displayDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusIcon(doc)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusIcon(_ doc: RecordingDocument) -> some View {
        switch pipeline.state(for: doc) {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).help("Queued")
        case .running:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Failed — open for details")
        case .done, nil:
            if doc.hasNotes {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Notes ready")
            } else if doc.hasTranscript {
                Image(systemName: "doc.text").foregroundStyle(.secondary).help("Transcript only")
            } else {
                Image(systemName: "record.circle").foregroundStyle(.secondary).help("Recorded — not yet transcribed")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailView(_ doc: RecordingDocument) -> some View {
        VStack(spacing: 0) {
            // Pipeline status banner for this document.
            if case .running(let stage) = pipeline.state(for: doc) {
                banner(icon: "gearshape.2", color: .blue, text: stage, spinning: true)
            } else if case .failed(let reason) = pipeline.state(for: doc) {
                banner(icon: "exclamationmark.triangle.fill", color: .orange, text: reason, spinning: false)
            }

            Picker("", selection: $detailTab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            ScrollView {
                markdownBody(for: doc)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(doc.displayTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    pipeline.enqueue(doc)
                } label: {
                    Label(doc.hasNotes ? "Regenerate" : "Generate notes", systemImage: "sparkles")
                }
                .disabled({ if case .running = pipeline.state(for: doc) { return true } else if case .queued = pipeline.state(for: doc) { return true } else { return false } }())
                .help("Run transcription + notes for this recording")

                Button {
                    let url = detailTab == .notes ? doc.notesURL : doc.transcriptURL
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the current tab's markdown")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.audioURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
    }

    private func banner(icon: String, color: Color, text: String, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(text).font(.caption).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
    }

    @ViewBuilder
    private func markdownBody(for doc: RecordingDocument) -> some View {
        let url = detailTab == .notes ? doc.notesURL : doc.transcriptURL
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            // Per-line markdown rendering: AttributedString(markdown:) is inline-only,
            // so headers/tables get light manual treatment for readability.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(raw.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    renderLine(line)
                }
            }
        } else {
            ContentUnavailableView(
                detailTab == .notes ? "No notes yet" : "No transcript yet",
                systemImage: "sparkles",
                description: Text("Click \"Generate notes\" in the toolbar to transcribe this recording and write notes.")
            )
            .padding(.top, 60)
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("# ") {
            Text(trimmed.dropFirst(2)).font(.title2).fontWeight(.bold).padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            Text(trimmed.dropFirst(3)).font(.headline).padding(.top, 8)
        } else if trimmed.hasPrefix("### ") {
            Text(trimmed.dropFirst(4)).font(.subheadline).fontWeight(.semibold).padding(.top, 4)
        } else if trimmed.hasPrefix("|") {
            Text(trimmed).font(.system(.caption, design: .monospaced))
        } else {
            Text((try? AttributedString(markdown: trimmed)) ?? AttributedString(trimmed))
                .font(.body)
        }
    }
}
