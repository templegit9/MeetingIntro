import SwiftUI

/// Add/edit a Quick Add template. Triggered by typing `/<trigger>` in the palette.
struct TemplateEditSheet: View {
    let template: QuickAddTemplate
    let links: [SavedMeetingLink]
    /// Other templates' triggers, for the duplicate check.
    let existingTriggers: [String]
    let onSave: (QuickAddTemplate) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var trigger: String = ""
    @State private var title: String = ""
    @State private var durationMinutes: Int = 30
    @State private var linkID: UUID?
    @State private var location: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(onDelete == nil ? "New Template" : "Edit Template")
                .font(.headline)
                .padding()
            Divider()

            Form {
                Section("Trigger") {
                    HStack(spacing: 2) {
                        Text("/").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        TextField("standup", text: $trigger)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Type /\(trigger.isEmpty ? "standup" : sanitizedTrigger) in Quick Add to use this template.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("Event") {
                    TextField("Title (e.g. Daily Standup)", text: $title)
                    Stepper(value: $durationMinutes, in: 5...480, step: 5) {
                        Text("Duration: \(durationMinutes) min")
                    }
                    TextField("Location (optional)", text: $location)
                }

                Section("Meeting link") {
                    Picker("Attach link", selection: $linkID) {
                        Text("None").tag(UUID?.none)
                        ForEach(links) { link in
                            Text(link.name).tag(UUID?.some(link.id))
                        }
                    }
                    if links.isEmpty {
                        Text("No saved links yet — add one under Meeting Links first.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 420, height: 520)
        .onAppear(perform: load)
    }

    /// Triggers are matched as a leading /token of letters/digits/hyphens — strip the rest.
    private var sanitizedTrigger: String {
        trigger.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func load() {
        trigger = template.trigger
        title = template.title
        durationMinutes = template.durationMinutes
        linkID = template.linkID
        location = template.location ?? ""
    }

    private func save() {
        error = nil
        let trig = sanitizedTrigger
        guard !trig.isEmpty else { error = "Give the template a trigger word."; return }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { error = "Give the event a title."; return }
        guard !existingTriggers.contains(where: { $0.compare(trig, options: .caseInsensitive) == .orderedSame }) else {
            error = "Another template already uses /\(trig)."; return
        }
        var t = template
        t.trigger = trig
        t.title = title.trimmingCharacters(in: .whitespaces)
        t.durationMinutes = durationMinutes
        t.linkID = linkID
        let loc = location.trimmingCharacters(in: .whitespaces)
        t.location = loc.isEmpty ? nil : loc
        onSave(t)
    }
}
