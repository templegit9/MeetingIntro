import SwiftUI

/// Reusable inline task fields (Issue #19), bound directly to a `TaskItem`. Used by the
/// popover's task composer (create/edit in the Tasks tab) and by the New Event form's task
/// branch (so a detected task gets notes/reminder fields inline). `showTitle` is off when the
/// title comes from another control (the New Event text field).
struct TaskFieldsForm: View {
    @Binding var task: TaskItem
    var showTitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showTitle {
                TextField("What needs doing?", text: $task.title).textFieldStyle(.roundedBorder)
            }
            Toggle("Has a due date", isOn: Binding(
                get: { task.dueDate != nil },
                set: { on in task.dueDate = on ? (task.dueDate ?? Self.defaultDue()) : nil }))
            if task.dueDate != nil {
                DatePicker("Due", selection: Binding(get: { task.dueDate ?? Date() }, set: { task.dueDate = $0 }))
                    .datePickerStyle(.compact)
            }
            TextField("Notes (optional)", text: Binding(
                get: { task.notes ?? "" },
                set: { task.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)

            if task.dueDate != nil {
                Divider().padding(.vertical, 2)
                Stepper(value: $task.remindLeadMinutes, in: 0...1440, step: 5) {
                    Text(task.remindLeadMinutes == 0 ? "Remind at the due time" : "Remind \(task.remindLeadMinutes) min before")
                        .font(.callout)
                }
                HStack(spacing: 14) {
                    Toggle("Overlay", isOn: $task.showOverlay)
                    Toggle("Notify", isOn: $task.sendNotification)
                    Toggle("Voice", isOn: $task.playVoice)
                }
                .toggleStyle(.checkbox).font(.caption)
            }
        }
    }

    /// Next round hour — a sensible default when a task first gets a due date.
    static func defaultDue() -> Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
    }
}
