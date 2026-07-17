import SwiftUI

/// Create or edit a task (Issue #19): title, optional due date/time, notes, reminder
/// lead, and per-task channels. Modeled on `TemplateEditSheet`/`RuleEditSheet`.
struct TaskEditSheet: View {
    let task: TaskItem
    let onSave: (TaskItem) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var title = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var notes = ""
    @State private var remindLeadMinutes = 0
    @State private var showOverlay = false
    @State private var sendNotification = true
    @State private var playVoice = false

    var body: some View {
        VStack(spacing: 0) {
            Text(onDelete == nil ? "New Task" : "Edit Task")
                .font(.headline).padding(.top, 16)

            Form {
                Section {
                    TextField("What needs doing?", text: $title)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Has a due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate)
                            .datePickerStyle(.compact)
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                if hasDueDate {
                    Section {
                        Stepper(value: $remindLeadMinutes, in: 0...1440, step: 5) {
                            Text(remindLeadMinutes == 0
                                 ? "Remind me at the due time"
                                 : "Remind me \(remindLeadMinutes) min before")
                        }
                        Toggle("Overlay", isOn: $showOverlay)
                        Toggle("System notification", isOn: $sendNotification)
                        Toggle("Voice", isOn: $playVoice)
                    } header: {
                        Text("Reminder")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) { onDelete() }
                }
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 460)
        .onAppear(perform: load)
    }

    private func load() {
        title = task.title
        hasDueDate = task.dueDate != nil
        dueDate = task.dueDate ?? defaultDue()
        notes = task.notes ?? ""
        remindLeadMinutes = task.remindLeadMinutes
        showOverlay = task.showOverlay
        sendNotification = task.sendNotification
        playVoice = task.playVoice
    }

    /// Next round hour, a sensible default for a new dated task.
    private func defaultDue() -> Date {
        let cal = Calendar.current
        return cal.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
    }

    private func save() {
        var updated = task
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.dueDate = hasDueDate ? dueDate : nil
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        updated.remindLeadMinutes = remindLeadMinutes
        updated.showOverlay = showOverlay
        updated.sendNotification = sendNotification
        updated.playVoice = playVoice
        onSave(updated)
    }
}
