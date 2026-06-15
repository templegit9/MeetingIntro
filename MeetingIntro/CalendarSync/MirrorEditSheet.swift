import SwiftUI

/// Add/edit a calendar mirror. Resolves the "new dedicated calendar" choice into
/// a real calendar ID (via `createCalendar`) before returning a complete Mirror.
struct MirrorEditSheet: View {
    let existing: Mirror?
    /// Loads the available calendars. The sheet loads these ITSELF (rather than
    /// receiving a snapshot) so a slow EventKit fetch on the parent tab can't leave
    /// the Sources list empty when the sheet opens — which silently blocked Create
    /// (the "pick at least one source" guard) even though the user had picked things.
    let loadCalendars: () async -> [CalendarInfo]
    let isWritable: (String) -> Bool
    let creatableSources: [EventKitProvider.CreatableSource]
    let defaultSourceID: String?
    /// Creates a dedicated calendar on the chosen source; returns id or nil.
    var createCalendar: (_ name: String, _ sourceID: String?) -> String?
    let onSave: (Mirror) -> Void
    let onCancel: () -> Void
    let diagnosticLog: DiagnosticLog

    @State private var calendars: [CalendarInfo] = []
    @State private var calendarsLoaded = false
    @State private var name: String = ""
    @State private var selectedSources: Set<String> = []
    @State private var useNewCalendar: Bool = true
    @State private var newCalendarName: String = "MeetingIntro Mirror"
    @State private var newCalendarSourceID: String = ""
    @State private var existingDestinationID: String = ""
    @State private var detailMode: Mirror.DetailMode = .busy
    @State private var deleteCopiesOnDisable: Bool = true
    @State private var error: String?

    private var writableCalendars: [CalendarInfo] {
        calendars.filter { isWritable($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New Mirror" : "Edit Mirror")
                .font(.headline)
                .padding()
            Divider()

            Form {
                Section("Name") {
                    TextField("e.g. Personal → Work", text: $name)
                }

                Section("Sources (calendars to mirror FROM)") {
                    if !calendarsLoaded {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading calendars…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if calendars.isEmpty {
                        Text("No calendars found. Make sure MeetingIntro has Calendar access in System Settings → Privacy.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(calendars) { cal in
                        Toggle(isOn: Binding(
                            get: { selectedSources.contains(cal.id) },
                            set: { on in
                                if on { selectedSources.insert(cal.id) } else { selectedSources.remove(cal.id) }
                            }
                        )) {
                            HStack {
                                Circle().fill(Color(hex: cal.color)).frame(width: 9, height: 9)
                                Text(cal.name)
                                Text(cal.source).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Destination (calendar to mirror INTO)") {
                    Picker("", selection: $useNewCalendar) {
                        Text("New dedicated calendar").tag(true)
                        Text("Existing calendar").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if useNewCalendar {
                        TextField("Calendar name", text: $newCalendarName)
                        Picker("Store in", selection: $newCalendarSourceID) {
                            ForEach(creatableSources) { src in
                                Text(src.isLocal ? "\(src.title) (this Mac only)" : src.title).tag(src.id)
                            }
                        }
                        Text("New calendars can only be created in iCloud (syncs to your Apple devices, shareable) or On My Mac (local only). **To store the mirror in Google or Microsoft/Outlook, create the destination calendar there first** (in Google Calendar / Outlook), let it sync to this Mac, then pick \"Existing calendar\" above and select it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Picker("Calendar", selection: $existingDestinationID) {
                            Text("Choose…").tag("")
                            ForEach(writableCalendars) { cal in
                                Text("\(cal.name) (\(cal.source))").tag(cal.id)
                            }
                        }
                        Text("Only writable calendars are listed — subscribed/holiday calendars can't receive mirrored events.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("Options") {
                    Picker("Detail", selection: $detailMode) {
                        ForEach(Mirror.DetailMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(detailMode == .busy
                         ? "Mirrored events show only as \"Busy\" — no titles or details leak."
                         : "Mirrored events copy title, location, and notes. (Attendees can't be copied — macOS limitation.)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("Delete the copies when I turn this mirror off", isOn: $deleteCopiesOnDisable)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                // Error sits in the always-visible bottom bar so a validation bail
                // can't hide below the fold of the scrolling form.
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button(existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!calendarsLoaded)
            }
            .padding()
        }
        .frame(width: 460, height: 620)
        .onAppear(perform: loadExisting)
        .task {
            calendars = await loadCalendars()
            calendarsLoaded = true
            diagnosticLog.info(.calendar, "Mirror sheet opened — \(calendars.count) calendars loaded, \(writableCalendars.count) writable, \(creatableSources.count) creatable sources")
        }
    }

    private func loadExisting() {
        newCalendarSourceID = defaultSourceID ?? creatableSources.first?.id ?? ""
        guard let m = existing else { return }
        name = m.name
        selectedSources = Set(m.sourceCalendarIDs)
        useNewCalendar = false
        existingDestinationID = m.destinationCalendarID
        detailMode = m.detailMode
        deleteCopiesOnDisable = m.deleteCopiesOnDisable
    }

    /// Set the error AND log it, so a silent validation bail is visible in Diagnostics.
    private func fail(_ message: String) {
        error = message
        diagnosticLog.warn(.calendar, "Mirror create blocked: \(message)")
    }

    private func save() {
        error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        diagnosticLog.info(.calendar, "Mirror Create tapped — name='\(trimmedName)', sources=\(selectedSources.count), newCalendar=\(useNewCalendar), existingDest=\(existingDestinationID.isEmpty ? "none" : "set")")
        guard !trimmedName.isEmpty else { fail("Give the mirror a name."); return }
        guard !selectedSources.isEmpty else { fail("Pick at least one source calendar."); return }

        // Resolve destination.
        let destinationID: String
        let isDedicated: Bool
        if useNewCalendar {
            // Editing an existing dedicated mirror keeps its calendar; only create
            // when this is genuinely new or switching to a new calendar.
            if let existing, existing.isDedicatedCalendar {
                destinationID = existing.destinationCalendarID
                isDedicated = true
            } else {
                let calName = newCalendarName.trimmingCharacters(in: .whitespaces)
                guard !calName.isEmpty else { fail("Name the new calendar."); return }
                let sourceID = newCalendarSourceID.isEmpty ? nil : newCalendarSourceID
                guard let id = createCalendar(calName, sourceID) else {
                    fail("Couldn't create the calendar in that account. Google/Microsoft don't allow it — create the calendar there first, then use \"Existing calendar.\"")
                    return
                }
                destinationID = id
                isDedicated = true
            }
        } else {
            guard !existingDestinationID.isEmpty else { fail("Choose a destination calendar."); return }
            guard isWritable(existingDestinationID) else { fail("That calendar is read-only."); return }
            destinationID = existingDestinationID
            isDedicated = false
        }

        // Loop guard: destination can't be a source.
        guard !selectedSources.contains(destinationID) else {
            fail("The destination can't also be a source."); return
        }

        var mirror = existing ?? Mirror(name: trimmedName, sourceCalendarIDs: [], destinationCalendarID: destinationID, isDedicatedCalendar: isDedicated)
        mirror.name = trimmedName
        mirror.sourceCalendarIDs = Array(selectedSources)
        mirror.destinationCalendarID = destinationID
        mirror.isDedicatedCalendar = isDedicated
        mirror.detailMode = detailMode
        mirror.deleteCopiesOnDisable = deleteCopiesOnDisable
        mirror.enabled = true
        mirror.paused = false
        mirror.lastError = nil
        onSave(mirror)
    }
}
