import SwiftUI

/// The Quick Add panel content: a large text field with a live event preview
/// underneath. Enter creates (when a draft exists), Esc dismisses.
/// Upward-pointing notch that visually ties the panel to the menu bar icon.
private struct NotchTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct QuickAddView: View {

    @ObservedObject var service: QuickAddService
    @ObservedObject var config: QuickAddConfig
    /// X position (in panel coordinates) the notch should point at — the menu
    /// bar icon's center. Nil → notch centered.
    var notchCenterX: CGFloat? = nil
    let onCreate: (EventDraft) async throws -> Void
    let onDismiss: () -> Void

    /// Near-opaque dark surface (reference-palette look) rather than light
    /// translucent material.
    private let surface = Color(red: 0.09, green: 0.10, blue: 0.12).opacity(0.97)

    @State private var isCreating = false
    @State private var createError: String?
    @State private var showSuccess = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Pointer notch aligned with the menu bar icon.
            HStack(spacing: 0) {
                Spacer().frame(width: max(12, (notchCenterX ?? 280) - 9))
                NotchTriangle()
                    .fill(surface)
                    .frame(width: 18, height: 9)
                Spacer()
            }
            panelBody
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity, alignment: .top)
        .colorScheme(.dark)
        .onAppear { inputFocused = true }
        .onExitCommand { onDismiss() }   // Esc
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Try: Lunch with Sam tomorrow 1pm", text: $service.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .focused($inputFocused)
                    .onSubmit { create() }
                if service.isParsing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            Group {
                if showSuccess {
                    Label("Event created", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 22)
                } else if let error = createError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(14)
                } else if let draft = service.draft {
                    previewCard(draft)
                } else if service.inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type an event in plain English — date, time, and place are picked out automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else if !templateSuggestions.isEmpty {
                    templateHint
                } else {
                    Text("Couldn't find a date or time in that yet…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
        }
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func previewCard(_ draft: EventDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                Text(draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(durationLabel(draft))
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            Text(dateLine(draft))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let location = draft.location, !location.isEmpty {
                Label(location, systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !config.meetingLinks.isEmpty {
                linkControl(draft)
            }
            if let notes = draft.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            // Anything the parser had to guess gets called out — a silent
            // assumption should never land on the calendar unnoticed.
            ForEach(draft.assumptions, id: \.self) { assumption in
                Label("\(assumption) — add it to the text to override", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Scheduling conflicts with existing meetings (Issue #10) — informational,
            // never blocks creation.
            if !service.conflicts.isEmpty {
                Label(conflictWarningText, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack {
                Text(draft.parserUsed.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(isCreating ? "Creating…" : "↩ to create · esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    /// Templates whose trigger matches the `/frag` typed so far.
    private var templateSuggestions: [QuickAddTemplate] {
        TemplateExpander.matches(forPrefix: service.inputText, templates: config.templates)
    }

    private var templateHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Templates").font(.caption2).foregroundStyle(.tertiary)
            ForEach(templateSuggestions) { t in
                Button {
                    service.inputText = "/\(t.trigger) "
                } label: {
                    HStack(spacing: 6) {
                        Text("/\(t.trigger)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                        Text(t.title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(t.durationMinutes) min").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Add a date/time after the trigger — e.g. /\(templateSuggestions.first?.trigger ?? "standup") tomorrow 9am")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Link attachment row: shows the attached meeting link (or "No meeting link")
    /// with a menu to switch which saved link, or remove it. Smart-attach pre-selects
    /// the default link for meeting-like phrases; this is the explicit override.
    private func linkControl(_ draft: EventDraft) -> some View {
        Menu {
            Button {
                service.linkChoice = .none
            } label: {
                Label("No link", systemImage: draft.url == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(config.meetingLinks) { link in
                Button {
                    service.linkChoice = .specific(link.id)
                } label: {
                    Label(link.name + (link.isDefault ? " (default)" : ""),
                          systemImage: draft.attachedLinkName == link.name ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: draft.url != nil ? "video.fill" : "video.slash.fill")
                    .foregroundStyle(draft.url != nil ? Color.accentColor : .secondary)
                Text(draft.attachedLinkName ?? (draft.url != nil ? "Meeting link" : "No meeting link"))
                    .foregroundStyle(draft.url != nil ? .primary : .secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func dateLine(_ draft: EventDraft) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        let time = DateFormatter()
        time.timeStyle = .short
        return "\(day.string(from: draft.startDate)) · \(time.string(from: draft.startDate)) – \(time.string(from: draft.endDate))"
    }

    /// "Overlaps 'Standup'" / "Overlaps 'Standup' + 2 more" — the conflict warning copy.
    private var conflictWarningText: String {
        let titles = service.conflicts
        guard let first = titles.first else { return "" }
        if titles.count == 1 { return "Overlaps “\(first)”" }
        return "Overlaps “\(first)” + \(titles.count - 1) more"
    }

    private func durationLabel(_ draft: EventDraft) -> String {
        let minutes = Int(draft.endDate.timeIntervalSince(draft.startDate) / 60)
        if minutes % 60 == 0 && minutes >= 60 {
            let h = minutes / 60
            return "\(h) hr" + (h > 1 ? "s" : "")
        }
        return "\(minutes) min"
    }

    private func create() {
        guard let draft = service.draft, !isCreating else { return }
        isCreating = true
        createError = nil
        Task { @MainActor in
            do {
                try await onCreate(draft)
                showSuccess = true
                try? await Task.sleep(nanoseconds: 700_000_000)
                onDismiss()
            } catch {
                createError = error.localizedDescription
            }
            isCreating = false
        }
    }
}
