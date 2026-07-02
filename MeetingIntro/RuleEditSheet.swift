import SwiftUI

/// Editor sheet for a single `NotificationRule` (Settings → Smart → Notification Rules).
/// Modeled on `TemplateEditSheet`: copies fields into `@State` on appear, validates, and
/// reports Save/Cancel/Delete via callbacks.
struct RuleEditSheet: View {
    let rule: NotificationRule
    let onSave: (NotificationRule) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var enabled = true
    @State private var titlePattern = ""
    @State private var condition: RuleCondition = .anyMeeting
    @State private var showOverlay = false
    @State private var sendNotification = true
    @State private var playVoice = false

    var body: some View {
        VStack(spacing: 0) {
            Text(onDelete == nil ? "New Rule" : "Edit Rule")
                .font(.headline).padding(.top, 16)

            Form {
                Section("Match meetings") {
                    TextField("Rule name (e.g. Focus Time)", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Title contains… (or a regex)", text: $titlePattern)
                        .textFieldStyle(.roundedBorder)
                    if !titlePattern.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Interpreted as: " + (NotificationRule.looksLikeRegex(titlePattern) ? "regular expression" : "contains (plain text)"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Picker("When", selection: $condition) {
                        ForEach(RuleCondition.allCases) { Text($0.label).tag($0) }
                    }
                    if condition == .justMe {
                        Text("Approximate — matches when the event has no other attendees (the app can't read your email address).")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Overlay", isOn: $showOverlay)
                    Toggle("System notification", isOn: $sendNotification)
                    Toggle("Voice", isOn: $playVoice)
                } header: {
                    Text("Allow only these channels")
                } footer: {
                    Text("For matching meetings, only the channels turned on here stay on — a rule can silence channels but never add ones the reminder threshold didn't already request.")
                        .font(.caption2)
                }

                Section {
                    Toggle("Rule enabled", isOn: $enabled)
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .onAppear(perform: load)
    }

    private func load() {
        name = rule.name
        enabled = rule.enabled
        titlePattern = rule.titlePattern
        condition = rule.condition
        showOverlay = rule.showOverlay
        sendNotification = rule.sendNotification
        playVoice = rule.playVoice
    }

    private func save() {
        var updated = rule
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.enabled = enabled
        updated.titlePattern = titlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.condition = condition
        updated.showOverlay = showOverlay
        updated.sendNotification = sendNotification
        updated.playVoice = playVoice
        onSave(updated)
    }
}
