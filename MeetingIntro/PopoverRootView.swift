import AppKit
import SwiftUI

/// The rich `.window`-style menu-bar popover (CodexBar-inspired). Phase 2 skeleton:
/// header with a Today/Upcoming segmented switcher + "synced" status + refresh, a
/// columned event list (today or a paged day), and action rows. Phases 3–4 add the
/// callout cards, the "NEXT" hero, the day-timeline, and the live ticker.
struct PopoverRootView: View {
    @ObservedObject var calendarManager: CalendarManager
    @ObservedObject var recordingController: RecordingController
    @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    @ObservedObject var updater: AppUpdater
    @ObservedObject var diagnosticLog: DiagnosticLog
    @ObservedObject var smartConfig: SmartConfigManager
    @ObservedObject var contextMonitor: MeetingContextMonitor
    @ObservedObject var quickAddService: QuickAddService
    @ObservedObject var quickAddConfig: QuickAddConfig
    @ObservedObject var taskManager: TaskManager

    /// #13: inline compact New Event form embedded in the rich popover.
    @State private var showingNewEvent = false
    @State private var creatingEvent = false
    @FocusState private var newEventFocused: Bool

    @Environment(\.openWindow) private var openWindow
    @AppStorage("cancellationShowInTodayView") private var showCancelled: Bool = true
    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex
    /// Opt-in (Settings → Menu Bar): size each list to its rows instead of reserving a
    /// fixed block, growing the popover up to 70% of the screen before it scrolls.
    @AppStorage("popoverFitToContent") private var fitDropdownToContent: Bool = false
    @AppStorage("assistantEnabled") private var assistantEnabled: Bool = false
    @AppStorage("dictionaryEnabled") private var dictionaryEnabled: Bool = false

    /// Hover-to-detail (Issue #16) — see CompactMenuView for the delay rationale.
    @State private var hoveredID: String?
    @State private var pendingHoverID: String?
    /// Task being created/edited inline in the popover (Issue #19). Non-nil → the task
    /// composer replaces the dropdown content (a `.sheet` won't present from the popover).
    @State private var editingTask: TaskItem?
    /// Working task for the New Event form's task branch (seeded from the parsed draft).
    @State private var newEventTask = TaskItem(title: "")
    /// Where this one event goes. Defaults to the Settings choice; picking an Outlook
    /// calendar here also routes the write (and its invitations) to Microsoft 365.
    @State private var newEventCalendarID: String?
    @State private var newEventCalendars: [CalendarInfo] = []
    @State private var showingDetails = false
    @State private var showingConflicts = false
    /// The draft after hand-editing in Details. nil means "whatever the parser says".
    @State private var editedDraft: EventDraft?

    private enum Tab { case today, upcoming, tasks }
    /// The expanded calendar (#32). Deliberately **not** persisted: a single click has
    /// to stay the fast glance, never a full calendar you must dismiss first.
    @State private var expanded = false
    @State private var tab: Tab = .today
    @State private var dayOffset = 1   // upcoming starts at tomorrow

    private var accent: Color { Color(hex: nextMeetingHighlightHex) }
    private var horizon: Int { calendarManager.upcomingDaysAhead }

    private var selectedDay: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var listEvents: [MeetingEvent] {
        let evts = tab == .today ? calendarManager.todaysMeetings : calendarManager.events(on: selectedDay)
        return showCancelled ? evts : evts.filter { !$0.isCancelled }
    }

    var body: some View {
        if expanded {
            ExpandedCalendarView(
                calendarManager: calendarManager,
                taskManager: taskManager,
                accent: accent,
                onCollapse: { expanded = false },
                onNewEvent: { expanded = false; showingNewEvent = true }
            )
        } else if showingNewEvent {
            newEventForm
        } else if editingTask != nil {
            taskComposer
        } else {
            popoverBody
        }
    }

    // MARK: - Task composer (Issue #19) — inline create/edit, replaces the dropdown content.

    private var taskComposer: some View {
        let editing = editingTask.map { t in taskManager.tasks.contains { $0.id == t.id } } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { editingTask = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(accent)
                Text(editing ? "Edit Task" : "New Task").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            TaskFieldsForm(task: Binding(get: { editingTask ?? TaskItem(title: "") }, set: { editingTask = $0 }))
            HStack {
                if editing {
                    Button("Delete", role: .destructive) {
                        if let t = editingTask { taskManager.delete(t.id) }
                        editingTask = nil
                    }
                }
                Spacer()
                Button("Save") { saveComposedTask() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((editingTask?.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onExitCommand { editingTask = nil }
    }

    private func saveComposedTask() {
        guard var t = editingTask else { return }
        t.title = t.title.trimmingCharacters(in: .whitespaces)
        guard !t.title.isEmpty else { return }
        if taskManager.tasks.contains(where: { $0.id == t.id }) { taskManager.update(t) } else { taskManager.add(t) }
        editingTask = nil
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tab == .today {
                // Hero + live-state cards tick once a second (countdowns). The event
                // list shows static start times, so it stays outside the TimelineView.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: 0) {
                        dayTimeline
                        heroBand
                        calloutCards
                    }
                }
                errorBanner
                if showSectionDivider { Divider() }
            }
            if tab == .upcoming { dayPager; Divider() }
            if tab == .tasks {
                tasksList
            } else {
                eventsList
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .onAppear {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let screenH = Int(NSScreen.main?.visibleFrame.height ?? 0)
            diagnosticLog.info(.calendar, "Popover opened — v\(v) screenH=\(screenH) todaysMeetings=\(calendarManager.todaysMeetings.count) shownInTab=\(listEvents.count) upcomingWeek=\(calendarManager.upcomingWeek.count) next=\(calendarManager.nextMeeting?.title ?? "none")")
        }
    }

    /// Whether to draw a divider between the hero/cards block and the event list.
    private var showSectionDivider: Bool {
        calendarManager.nextMeeting != nil
            || recordingController.isRecording
            || !calendarManager.armedAutoJoinMeetings.isEmpty
            || !calendarManager.pendingCancellations.isEmpty
            || !calendarManager.pendingReschedules.isEmpty
            || isUpdateAvailable
            || remindersMutedByCall
            || calendarManager.errorMessage != nil
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.state { return true }
        return false
    }

    /// Reminders currently muted by the in-call rule (mic in use elsewhere).
    private var remindersMutedByCall: Bool {
        smartConfig.suppressWhenInCall && contextMonitor.snapshot.isInActiveCall
    }

    // MARK: - New Event (Issue #13, embedded in the rich popover)

    private var newEventForm: some View {
        Group {
            if showingDetails { eventDetailsEditor } else { quickAddForm }
        }
        .frame(width: 340, alignment: .leading)
        .onAppear {
            newEventFocused = true
            newEventTask = TaskItem(title: "")
            newEventCalendarID = quickAddConfig.defaultCalendarID
            Task { newEventCalendars = await calendarManager.writableCalendarsFromEnabledSources() }
        }
        .onExitCommand { closeNewEvent() }
        // Typing again makes the text the source of truth once more, so hand edits from
        // the Details screen are dropped rather than silently overriding what you typed.
        .onChange(of: quickAddService.inputText) { _, _ in editedDraft = nil; showingConflicts = false }
    }

    private func closeNewEvent() {
        showingNewEvent = false
        showingDetails = false
        editedDraft = nil
        showingConflicts = false
        quickAddService.reset()
    }

    /// The draft that will actually be created: the hand-edited one when the Details
    /// screen has been used, otherwise whatever the parser last produced.
    private var effectiveDraft: EventDraft? { editedDraft ?? quickAddService.draft }

    // MARK: Quick add

    private var quickAddForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { closeNewEvent() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(accent).help("Dismiss")
                Text("New event").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let draft = quickAddService.draft {
                    Picker("", selection: Binding(get: { draft.kind }, set: { quickAddService.kindOverride = $0 })) {
                        Text("Event").tag(DraftKind.event)
                        Text("Task").tag(DraftKind.task)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 116)
                }
            }

            // The field carries the chips lifted out of the text, so a modifier like
            // "all day" reads as a setting instead of ending up in the event's name.
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                ForEach(quickAddService.tokens) { token in
                    Button { quickAddService.removeToken(token) } label: {
                        HStack(spacing: 3) {
                            Text(token.label).font(.system(size: 11, weight: .semibold))
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(token.label)")
                }
                TextField("Month Meeting", text: $quickAddService.inputText)
                    .textFieldStyle(.plain)
                    .focused($newEventFocused)
                    .onSubmit { create() }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(newEventFocused ? accent : Color.secondary.opacity(0.28),
                            lineWidth: newEventFocused ? 2 : 1)
            )

            Text("Type naturally — “lunch with Sam tomorrow 1pm”")
                .font(.caption2).foregroundStyle(.secondary)

            if let draft = effectiveDraft {
                previewCard(draft)
                checksCard(draft)
            } else if !quickAddService.inputText.isEmpty {
                Text(quickAddService.isParsing ? "Parsing…" : "Keep typing…")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                keycap("↩"); Text("create").font(.caption2).foregroundStyle(.tertiary)
                keycap("esc"); Text("cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(creatingEvent ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(effectiveDraft == nil || creatingEvent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }

    /// What the event will be, with the two choices that decide where it lands and how
    /// it is joined. Everything else lives behind Edit.
    @ViewBuilder private func previewCard(_ draft: EventDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title).font(.system(.callout, weight: .semibold)).lineLimit(1)
                    Text(subtitle(for: draft))
                        .font(.caption)
                        .foregroundStyle(draft.assumptions.isEmpty ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer()
                if draft.kind == .event {
                    Button("Edit") { openDetails() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                }
            }

            if draft.kind == .event {
                newEventLinkControl(draft)
                newEventCalendarControl
                if !draft.attendees.isEmpty { inviteeNote(draft) }
            } else {
                taskExtras
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func subtitle(for draft: EventDraft) -> String {
        let day = draft.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let when = draft.isAllDay ? "all day" : draft.startDate.formatted(date: .omitted, time: .shortened)
        let prefix = draft.kind == .task ? "Due " : ""
        let assumed = draft.assumptions.isEmpty ? "" : " (assumed)"
        return "\(prefix)\(day) · \(when)\(assumed)"
    }

    /// Assumptions and conflicts in one place. Loose orange labels scattered down the
    /// form read as decoration; one counted box reads as something to answer.
    @ViewBuilder private func checksCard(_ draft: EventDraft) -> some View {
        let conflicts = draft.kind == .event ? quickAddService.conflicts : []
        let count = draft.assumptions.count + (conflicts.isEmpty ? 0 : 1)
        if count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    Text("\(count) thing\(count == 1 ? "" : "s") to check")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                }
                Text(checksSentence(draft, conflicts: conflicts))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showingConflicts, !conflicts.isEmpty {
                    ForEach(conflicts, id: \.self) { title in
                        Label(title, systemImage: "calendar.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if !draft.assumptions.isEmpty {
                        Button("Pick a date") { openDetails() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if !conflicts.isEmpty {
                        Button(showingConflicts ? "Hide conflict" : "View conflict") {
                            showingConflicts.toggle()
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    private func checksSentence(_ draft: EventDraft, conflicts: [String]) -> String {
        var parts = draft.assumptions
        if let first = conflicts.first {
            let more = conflicts.count > 1 ? " and \(conflicts.count - 1) more" : ""
            parts.append("It also overlaps \(first)\(more).")
        }
        return parts.joined(separator: " ")
    }

    /// Only Microsoft 365 can send invitations; say so against the calendar actually
    /// picked, not the app-wide default.
    @ViewBuilder private func inviteeNote(_ draft: EventDraft) -> some View {
        let canInvite = selectedCalendarProvider == .microsoftGraph
        Label(canInvite
              ? "Inviting \(draft.attendees.joined(separator: ", "))"
              : "\(draft.attendees.count) invitee\(draft.attendees.count == 1 ? "" : "s") won't be invited — macOS Calendar can't send invitations.",
              systemImage: canInvite ? "person.crop.circle.badge.plus" : "person.crop.circle.badge.exclamationmark")
            .font(.caption2)
            .foregroundStyle(canInvite ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var taskExtras: some View {
        TextField("Notes (optional)", text: Binding(
            get: { newEventTask.notes ?? "" },
            set: { newEventTask.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
            .lineLimit(1...3).textFieldStyle(.roundedBorder).font(.caption)
        Stepper(value: $newEventTask.remindLeadMinutes, in: 0...1440, step: 5) {
            Text(newEventTask.remindLeadMinutes == 0 ? "Remind at due time" : "Remind \(newEventTask.remindLeadMinutes) min before")
                .font(.caption)
        }
        HStack(spacing: 12) {
            Toggle("Overlay", isOn: $newEventTask.showOverlay)
            Toggle("Notify", isOn: $newEventTask.sendNotification)
            Toggle("Voice", isOn: $newEventTask.playVoice)
        }
        .toggleStyle(.checkbox).font(.caption)
    }

    // MARK: Details

    private func openDetails() {
        editedDraft = effectiveDraft
        showingDetails = true
    }

    /// Binding into the edited draft. Details is only reachable with a draft in hand,
    /// so the fallback is never displayed — it exists to keep the bindings non-optional.
    private var draftBinding: Binding<EventDraft> {
        Binding(
            get: { editedDraft ?? quickAddService.draft ?? EventDraft(title: "", startDate: Date(), endDate: Date(), parserUsed: .detector) },
            set: { editedDraft = $0 }
        )
    }

    private var eventDetailsEditor: some View {
        let draft = draftBinding
        return VStack(alignment: .leading, spacing: 10) {
            ZStack {
                HStack {
                    Button { showingDetails = false } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Quick add").font(.caption)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(accent)
                    Spacer()
                }
                Text("Details").font(.system(size: 13, weight: .semibold))
            }

            TextField("Title", text: draft.title)
                .textFieldStyle(.plain)
                .font(.system(.body, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 2))

            VStack(spacing: 0) {
                detailRow("Starts") {
                    HStack {
                        DatePicker("", selection: draft.startDate,
                                   displayedComponents: draft.wrappedValue.isAllDay ? [.date] : [.date, .hourAndMinute])
                            .labelsHidden().datePickerStyle(.field)
                        Spacer()
                        Toggle("all day", isOn: draft.isAllDay)
                            .toggleStyle(.button).font(.caption)
                    }
                }
                Divider().padding(.leading, 74)
                detailRow("Ends") {
                    DatePicker("", selection: draft.endDate,
                               displayedComponents: draft.wrappedValue.isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.field)
                }
                Divider().padding(.leading, 74)
                detailRow("Repeat") {
                    Menu {
                        ForEach(DraftRecurrence.options(for: draft.wrappedValue.startDate), id: \.?.id) { option in
                            Button(option?.label() ?? "Never") { editedDraft?.recurrence = option }
                        }
                    } label: {
                        Text(draft.wrappedValue.recurrence?.label() ?? "Never").font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 0) {
                detailRow("Calendar") { newEventCalendarControl }
                Divider().padding(.leading, 74)
                detailRow("Meet") { newEventLinkControl(draft.wrappedValue) }
                Divider().padding(.leading, 74)
                detailRow("Guests") {
                    TextField("Add people", text: Binding(
                        get: { draft.wrappedValue.attendees.joined(separator: ", ") },
                        set: { text in
                            // Only addresses. A name is not an address, and inviting the
                            // wrong person cannot be taken back.
                            editedDraft?.attendees = text
                                .split(whereSeparator: { ",; ".contains($0) })
                                .map(String.init)
                                .filter { $0.contains("@") }
                        }))
                        .textFieldStyle(.plain).font(.callout)
                }
                Divider().padding(.leading, 74)
                detailRow("Notes") {
                    TextField("Add a note", text: Binding(
                        get: { draft.wrappedValue.notes ?? "" },
                        set: { editedDraft?.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.plain).font(.callout)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                keycap("⌘↩"); Text("create").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { closeNewEvent() }.buttonStyle(.plain).font(.callout)
                Button(creatingEvent ? "Creating…" : "Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(creatingEvent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
    }

    private func detailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func create() {
        guard let draft = effectiveDraft, !creatingEvent else { return }
        creatingEvent = true
        Task {
            if draft.kind == .task {
                var t = newEventTask
                t.title = draft.title
                t.dueDate = draft.startDate
                if t.notes == nil { t.notes = draft.notes }
                taskManager.add(t)
            } else {
                try? await calendarManager.createEvent(from: draft, calendarID: newEventCalendarID)
            }
            creatingEvent = false
            closeNewEvent()
        }
    }

    /// Meeting-link attach/switch/remove (mirrors QuickAddView.linkControl) so the
    /// embedded form has the same link affordance as the old floating panel.
    /// Which source will receive the event, derived from the picked calendar so the
    /// invitee note below tells the truth about *this* event.
    private var selectedCalendarProvider: CalendarProviderType {
        newEventCalendars.first { $0.id == newEventCalendarID }?.providerType
            ?? calendarManager.eventCreationProvider
    }

    /// Calendar picker. With two sources connected, "where does this land" is a real
    /// question — and the answer decides whether invitations can be sent at all, so it
    /// belongs in the form rather than only in Settings.
    @ViewBuilder private var newEventCalendarControl: some View {
        let selected = newEventCalendars.first { $0.id == newEventCalendarID }
        Menu {
            Button {
                newEventCalendarID = nil
            } label: {
                Label("Default calendar", systemImage: newEventCalendarID == nil ? "checkmark" : "calendar")
            }
            if !newEventCalendars.isEmpty { Divider() }
            ForEach(newEventCalendars) { cal in
                Button {
                    newEventCalendarID = cal.id
                } label: {
                    Label("\(cal.name) · \(cal.source)",
                          systemImage: newEventCalendarID == cal.id ? "checkmark" : "calendar")
                }
            }
        } label: {
            Label(selected.map { "\($0.name) · \($0.source)" } ?? "Default calendar",
                  systemImage: "calendar")
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func newEventLinkControl(_ draft: EventDraft) -> some View {
        Menu {
            Button { quickAddService.linkChoice = .none } label: {
                Label("No link", systemImage: draft.url == nil ? "checkmark" : "")
            }
            if !quickAddConfig.meetingLinks.isEmpty { Divider() }
            ForEach(quickAddConfig.meetingLinks) { link in
                Button { quickAddService.linkChoice = .specific(link.id) } label: {
                    Label(link.name + (link.isDefault ? " (default)" : ""),
                          systemImage: draft.attachedLinkName == link.name ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: draft.url != nil ? "video.fill" : "video.slash.fill")
                    .foregroundStyle(draft.url != nil ? accent : .secondary)
                Text(draft.attachedLinkName ?? (draft.url != nil ? "Meeting link" : "No meeting link"))
                    .foregroundStyle(draft.url != nil ? .primary : .secondary)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            segment("Today", isOn: tab == .today) { tab = .today }
            segment("Upcoming", isOn: tab == .upcoming) { tab = .upcoming }
            segment("Tasks", isOn: tab == .tasks) { tab = .tasks }
            Spacer()
            // Compact age, and it has to actually count. The header sits outside the
            // body's 1s TimelineView, so a seconds display rendered here would freeze at
            // whatever it read when the popover opened — "0s" forever. Only this one
            // Text gets its own ticker; re-rendering the whole header every second would
            // fight the layout the tabs depend on.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(syncedText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(syncedHelp)
            }
            .layoutPriority(-1)
            Button { Task { await calendarManager.refreshEvents() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.borderless).help("Refresh").padding(.leading, 4)
            // Expand in place (#32). Two entry points, both from the design note: this
            // control and ⌘⇧C. The originally-specced double-click on the menu bar icon
            // is not reachable from a `.window` MenuBarExtra — see ExpandedCalendarView.
            Button { expanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Full calendar (⌘⇧C)")
            .padding(.leading, 1)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? accent : .secondary)
                // Never wrap or compress: adding the expand control to this row made
                // "Upcoming" break across two lines. The tabs hold their width and the
                // synced label gives way instead.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(isOn ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// Age of the last successful sync, as short as it can be read: 0s, 45s, 3m, 2h.
    /// The word "synced" was costing more header width than it earned — the icon beside
    /// it already says what this is, and the tooltip carries the long form.
    private var syncedText: String {
        guard let date = calendarManager.lastRefreshDate else { return "—" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }

    private var syncedHelp: String {
        guard calendarManager.lastRefreshDate != nil else { return "Not synced yet" }
        return syncedText == "0s" ? "Synced just now" : "Synced \(syncedText) ago"
    }

    // MARK: - Day timeline (Today)

    /// Horizontal "blocks across the workday" bar for today's timed meetings, with a
    /// live now-marker. Next meeting = accent, currently-recording = red, others muted.
    @ViewBuilder private var dayTimeline: some View {
        let cal = Calendar.current
        let timed = calendarManager.todaysMeetings.filter {
            !$0.isAllDay && !$0.isCancelled && cal.isDateInToday($0.startDate)
        }
        if !timed.isEmpty {
            DayTimelineBar(
                meetings: timed,
                nextID: calendarManager.nextMeeting?.id,
                recordingTitle: recordingController.isRecording ? recordingController.currentMeetingTitle : nil,
                accent: accent
            )
            .frame(height: 10)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
        }
    }

    // MARK: - Hero (Today)

    @ViewBuilder private var heroBand: some View {
        if let next = calendarManager.nextMeeting,
           Calendar.current.isDateInToday(next.startDate), next.startDate > Date() {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("NEXT").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Text(relativeStart(next)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                    Spacer()
                    Text(next.formattedStartTime).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                }
                Text(next.title).font(.system(.subheadline, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.07))
        }
    }

    private func relativeStart(_ meeting: MeetingEvent) -> String {
        let secs = Int(meeting.startDate.timeIntervalSinceNow)
        guard secs > 0 else { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 && m > 0 { return "in \(h)h \(m)m" }
        if h > 0 { return "in \(h)h" }
        return "in \(max(1, m))m"
    }

    // MARK: - Callout cards (Today)

    @ViewBuilder private var calloutCards: some View {
        if recordingController.isRecording, let title = recordingController.currentMeetingTitle {
            calloutCard(icon: "record.circle.fill", tint: .red, title: "Recording — \(title)", actionLabel: "Stop") {
                Task { await recordingCoordinator.stopManually() }
            }
        }
        ForEach(calendarManager.armedAutoJoinMeetings) { m in
            calloutCard(icon: "clock.badge.checkmark", tint: accent,
                        title: "\(m.title) · \(m.formattedStartTime)", actionLabel: "Cancel") {
                calendarManager.disarmAutoJoin(m.id)
            }
        }
        if case .available(let v) = updater.state {
            calloutCard(icon: "arrow.down.circle.fill", tint: accent, title: "Update available — v\(v)", actionLabel: "Install") {
                Task { await updater.update() }
            }
        }
        ForEach(calendarManager.pendingCancellations) { m in
            calloutCard(icon: "xmark.circle.fill", tint: .orange,
                        title: "\(m.formattedStartTime)  \(m.title)", actionLabel: "Dismiss") {
                calendarManager.dismissCancellation(m.id)
            }
        }
        // Reschedules (#28). Cancellations already persisted and surfaced here; a moved
        // meeting fired one notification and left no trace, so missing the banner meant
        // missing the move. Same treatment, same dismiss gesture.
        ForEach(calendarManager.pendingReschedules) { change in
            calloutCard(icon: "calendar.badge.clock", tint: .orange,
                        title: "\(change.title) · \(change.summary)", actionLabel: "Dismiss") {
                calendarManager.acknowledgeScheduleChange(change.id)
            }
        }
        if remindersMutedByCall {
            calloutCard(icon: "bell.slash.fill", tint: .orange, title: "Reminders paused — you're on a call")
        }
    }

    private func calloutCard(icon: String, tint: Color, title: String, actionLabel: String, action: @escaping () -> Void) -> some View {
        calloutCardContent(icon: icon, tint: tint, title: title) {
            Button(actionLabel, action: action).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).buttonStyle(.borderless)
        }
    }

    /// Informational variant — same styling, no trailing action button.
    private func calloutCard(icon: String, tint: Color, title: String) -> some View {
        calloutCardContent(icon: icon, tint: tint, title: title) { EmptyView() }
    }

    private func calloutCardContent<Trailing: View>(icon: String, tint: Color, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 20)
            Text(title).font(.system(.caption, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 14).padding(.vertical, 3)
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = calendarManager.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    // MARK: - Day pager (Upcoming)

    private var dayPager: some View {
        HStack(spacing: 6) {
            Button { if dayOffset > 1 { dayOffset -= 1 } } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(.borderless).disabled(dayOffset <= 1).foregroundStyle(dayOffset <= 1 ? Color.secondary : accent)
            Spacer()
            Text(UpcomingDayFormat.longHeader(for: selectedDay)).font(.system(.subheadline, weight: .semibold))
            Spacer()
            Button { if dayOffset < horizon { dayOffset += 1 } } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)) }
                .buttonStyle(.borderless).disabled(dayOffset >= horizon).foregroundStyle(dayOffset >= horizon ? Color.secondary : accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Events

    /// Height of the rows inside each list, measured at layout time. Sizing on the
    /// *measured* content (rather than letting a flexible frame decide) is what lets the
    /// popover fit exactly — and it's also why this can't reintroduce the v2.9.4 bug,
    /// where a flexible list got squeezed to ~0 on a shorter display. An explicit height
    /// can't be squeezed.
    @State private var eventsContentHeight: CGFloat = 0
    @State private var tasksContentHeight: CGFloat = 0

    /// Ceiling for a list when fit-to-content is on: the popover as a whole shouldn't
    /// exceed 70% of the screen, so the list gets that minus the fixed chrome above and
    /// below it (header, timeline, NEXT band, footer actions). Floored so a very short
    /// display still shows something scrollable rather than a sliver.
    private var listHeightCap: CGFloat {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return max(160, screen * 0.70 - Self.popoverChromeHeight)
    }

    /// Measured height of everything in the popover that isn't the list: header ~44,
    /// timeline ~22, NEXT band ~56, footer rows + dividers ~230.
    private static let popoverChromeHeight: CGFloat = 350

    /// Fitted height for a list: never below one row's worth, never above the cap — and
    /// **snapped to whole rows** so the bottom edge always lands between rows instead of
    /// slicing one in half against the footer.
    ///
    /// The row height is derived from the measurement itself (`(measured - padding) /
    /// rowCount`) rather than a hardcoded constant, so it stays exact if a row's font or
    /// padding ever changes.
    private func fittedHeight(_ measured: CGFloat, rowCount: Int) -> CGFloat {
        let capped = min(max(measured, 44), listHeightCap)
        guard rowCount > 0, measured > Self.listVerticalPadding else { return capped }
        let rowHeight = (measured - Self.listVerticalPadding) / CGFloat(rowCount)
        guard rowHeight > 1 else { return capped }
        let wholeRows = floor((capped - Self.listVerticalPadding) / rowHeight)
        guard wholeRows >= 1 else { return capped }
        return wholeRows * rowHeight + Self.listVerticalPadding
    }

    /// The `.padding(.vertical, 2)` on each list's VStack, top + bottom.
    private static let listVerticalPadding: CGFloat = 4

    /// A soft fade over the last few points of a scrollable list. Used on the legacy
    /// (fit-off) path, where the frame height is decided by the parent, so we can't snap
    /// to whole rows — without it, a half-row sits flush against the footer and reads as
    /// a rendering bug rather than "there's more below".
    private func bottomFade(active: Bool) -> LinearGradient {
        LinearGradient(
            stops: active
                ? [.init(color: .black, location: 0),
                   .init(color: .black, location: 0.88),
                   .init(color: .black.opacity(0.15), location: 1)]
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var eventsList: some View {
        Group {
            if listEvents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 26, weight: .thin)).foregroundStyle(.tertiary)
                    Text(tab == .today ? "No meetings today" : "No meetings").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                // The two modes are kept as SEPARATE view trees on purpose. Measuring in
                // both — a GeometryReader background feeding @State — wrote state on
                // every layout pass, so with the toggle OFF the old path picked up a
                // re-render per scroll frame and felt janky. Off means untouched.
                if fitDropdownToContent {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(listEvents) { eventRow($0) }
                        }
                        .padding(.vertical, 2)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: EventsHeightKey.self, value: proxy.size.height)
                        })
                    }
                    .onPreferenceChange(EventsHeightKey.self) { height in
                        // Sub-point churn would re-render for nothing.
                        if abs(height - eventsContentHeight) > 0.5 { eventsContentHeight = height }
                    }
                    .frame(height: fittedHeight(eventsContentHeight, rowCount: listEvents.count))
                    .scrollIndicators(eventsContentHeight > listHeightCap ? .automatic : .never)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(listEvents) { eventRow($0) }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 140, maxHeight: 300)
                    .scrollBounceBehavior(.basedOnSize)
                    // Purely visual: no measurement, no state — the jank in v2.19.0 came
                    // from measuring on this path, so it stays measurement-free.
                    .mask(bottomFade(active: listEvents.count >= 5))
                }
            }
        }
    }

    // MARK: - Tasks (Issue #19)

    private var tasksList: some View {
        VStack(spacing: 0) {
            if taskManager.tasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 26, weight: .thin)).foregroundStyle(.tertiary)
                    Text("No tasks").font(.callout).foregroundStyle(.secondary)
                    Text("Add one below, or type “Submit report by Fri 5pm” in New Event")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                if fitDropdownToContent {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(taskManager.sorted) { taskRow($0) }
                        }
                        .padding(.vertical, 2)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: TasksHeightKey.self, value: proxy.size.height)
                        })
                    }
                    .onPreferenceChange(TasksHeightKey.self) { height in
                        if abs(height - tasksContentHeight) > 0.5 { tasksContentHeight = height }
                    }
                    .frame(height: fittedHeight(tasksContentHeight, rowCount: taskManager.sorted.count))
                    .scrollIndicators(tasksContentHeight > listHeightCap ? .automatic : .never)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(taskManager.sorted) { taskRow($0) }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 120, maxHeight: 300)
                    .scrollBounceBehavior(.basedOnSize)
                    .mask(bottomFade(active: taskManager.sorted.count >= 5))
                }
            }
            HStack {
                Button { editingTask = taskManager.makeTask(title: "", dueDate: nil) } label: {
                    Label("New task", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(accent)
                Spacer()
                if taskManager.hasCompleted {
                    Button("Clear completed") { taskManager.deleteCompleted() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(spacing: 8) {
            Button { taskManager.toggleComplete(task.id) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.green : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            Button { editingTask = task } label: {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if !task.dueLabel.isEmpty {
                Text(task.dueLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(task.isOverdue ? .red : .secondary)
                    .lineLimit(1)
            }
            Menu {
                Button("Edit…") { editingTask = task }
                Button(task.isCompleted ? "Mark not done" : "Mark done") { taskManager.toggleComplete(task.id) }
                Button("Delete", role: .destructive) { taskManager.delete(task.id) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { inside in handleHover(inside, task.id) }
        .popover(isPresented: Binding(
            get: { hoveredID == task.id },
            set: { if !$0 { hoveredID = nil } }
        ), arrowEdge: .trailing) {
            TaskHoverCard(task: task)
        }
    }

    private func eventRow(_ meeting: MeetingEvent) -> some View {
        let isNext = meeting.id == calendarManager.nextMeeting?.id
        let inProgress = meeting.startDate <= Date() && Date() < meeting.endDate
        return HStack(spacing: 8) {
            Circle().fill(Color.green).frame(width: 7, height: 7).opacity(inProgress ? 1 : 0)
            Text(meeting.formattedStartTime)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isNext ? accent : .secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            Text(meeting.title)
                .font(.body).fontWeight(isNext ? .semibold : .regular)
                .strikethrough(meeting.isCancelled)
                .foregroundStyle(meeting.isCancelled ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let glyph = meeting.myResponse.todayGlyph, !meeting.isCancelled {
                Image(systemName: glyph).font(.caption2)
                    .foregroundStyle(meeting.myResponse == .declined ? .red : .secondary)
            }
            if let url = meeting.url, !meeting.isCancelled {
                Button { calendarManager.markJoined(meeting.id); NSWorkspace.shared.open(url) } label: { Image(systemName: "video.fill").foregroundStyle(.green) }
                    .buttonStyle(.borderless).help("Join")
            }
            if !meeting.isCancelled {
                Menu {
                    // Copy actions (#31 copy link, #25 copy details). Each is hidden
                    // when the meeting has nothing of that kind, so no item ever
                    // silently copies an empty string.
                    if MeetingClipboard.has(.link, meeting) {
                        Button("Copy Join Link") { MeetingClipboard.copy(.link, of: meeting) }
                    }
                    Button("Copy Details") { MeetingClipboard.copy(.details, of: meeting) }
                    if MeetingClipboard.has(.notes, meeting) {
                        Button("Copy Notes") { MeetingClipboard.copy(.notes, of: meeting) }
                    }
                    Divider()
                    if calendarManager.canRespond(to: meeting),
                       [.accepted, .declined, .tentative, .noResponse].contains(meeting.myResponse) {
                        Button("Accept") { Task { try? await calendarManager.respond(to: meeting.id, status: .accepted) } }
                        Button("Tentative") { Task { try? await calendarManager.respond(to: meeting.id, status: .tentative) } }
                        Button("Decline") { Task { try? await calendarManager.respond(to: meeting.id, status: .declined) } }
                        Divider()
                    }
                    if calendarManager.remindersDismissed(meeting.id) {
                        Button("Re-enable reminders") { calendarManager.undismissReminders(meeting.id) }
                    } else {
                        Button("Dismiss reminders for this event") { calendarManager.dismissReminders(meeting.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { inside in handleHover(inside, meeting.id) }
        .popover(isPresented: Binding(
            get: { hoveredID == meeting.id },
            set: { if !$0 { hoveredID = nil } }
        ), arrowEdge: .trailing) {
            MeetingHoverCard(meeting: meeting)
        }
    }

    /// Show the detail card after a brief dwell; hide immediately on exit.
    private func handleHover(_ inside: Bool, _ id: String) {
        if inside {
            pendingHoverID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if pendingHoverID == id { hoveredID = id }
            }
        } else {
            if pendingHoverID == id { pendingHoverID = nil }
            if hoveredID == id { hoveredID = nil }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow("New Event", "plus", "⌘N") {
                quickAddService.reset()
                showingNewEvent = true
            }
            footerDivider
            footerRow("Meeting Notes", "note.text", "⌘M") { openWindow(id: "meetingNotes"); NSApp.activate(ignoringOtherApps: true) }
            footerDivider
            if assistantEnabled || dictionaryEnabled {
                pluginFooter
                footerDivider
            }
            SettingsLink { footerLabel("Settings", "gearshape", "⌘,") }.buttonStyle(.plain)
            footerDivider
            footerRow("Quit MeetingIntro", "power", "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 4)
    }

    /// Thin, low-contrast separator between footer rows (inset from the popover edges).
    private var footerDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 10)
    }

    private func footerRow(_ label: String, _ symbol: String, _ shortcut: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { footerLabel(label, symbol, shortcut) }.buttonStyle(.plain)
    }

    /// The plugin footer entries. When both plugins are enabled they share one row, split by
    /// label length ("File Organizer…" wider than "Dictionary…"); a single one is a full row.
    @ViewBuilder private var pluginFooter: some View {
        let items: [(label: String, symbol: String, id: String, sc: String)] = {
            var a: [(String, String, String, String)] = []
            if assistantEnabled { a.append(("File Organizer", "folder.badge.gearshape", "assistant", "⌥⌘A")) }
            if dictionaryEnabled { a.append(("Dictionary", "character.book.closed", "dictionary", "⌥⌘D")) }
            return a.map { ($0.0, $0.1, $0.2, $0.3) }
        }()
        if items.count == 1 {
            footerRow(items[0].label, items[0].symbol, items[0].sc) { openWindow(id: items[0].id); NSApp.activate(ignoringOtherApps: true) }
        } else if items.count == 2 {
            GeometryReader { geo in
                let half = (geo.size.width - 1) / 2   // equal halves, minus the 1px divider
                HStack(spacing: 0) {
                    pluginCell(items[0], width: half)
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)   // short centered hairline
                    pluginCell(items[1], width: half)
                }
            }
            .frame(height: 26)
        }
    }

    private func pluginCell(_ item: (label: String, symbol: String, id: String, sc: String), width: CGFloat) -> some View {
        Button {
            openWindow(id: item.id); NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(item.label).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    private func footerLabel(_ label: String, _ symbol: String, _ shortcut: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(label)
            Spacer()
            Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle()).padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// The day-timeline hero bar: today's timed meetings as blocks across a workday window,
/// with a live now-marker. Window auto-expands to fit early/late meetings (default 9–19h).
private struct DayTimelineBar: View {
    let meetings: [MeetingEvent]
    let nextID: String?
    let recordingTitle: String?
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let cal = Calendar.current
            let dayStart = cal.startOfDay(for: Date())
            let offsets = meetings.map { $0.startDate.timeIntervalSince(dayStart) }
            let ends = meetings.map { $0.endDate.timeIntervalSince(dayStart) }
            let winStart = min(9 * 3600, offsets.min() ?? 9 * 3600)
            let winEnd = max(19 * 3600, ends.max() ?? 19 * 3600)
            let span = max(1, winEnd - winStart)
            let w = geo.size.width
            let frac: (TimeInterval) -> CGFloat = { t in CGFloat(min(max((t - winStart) / span, 0), 1)) }

            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 6)

                ForEach(meetings) { m in
                    let x = frac(m.startDate.timeIntervalSince(dayStart)) * w
                    let endX = frac(m.endDate.timeIntervalSince(dayStart)) * w
                    let bw = max(3, endX - x)
                    Capsule()
                        .fill(blockColor(m))
                        .frame(width: bw, height: 6)
                        .offset(x: min(x, w - bw))
                }

                // Now marker
                let nowOff = Date().timeIntervalSince(dayStart)
                if nowOff >= winStart && nowOff <= winEnd {
                    Rectangle().fill(Color.primary)
                        .frame(width: 1.5, height: 10)
                        .offset(x: frac(nowOff) * w - 0.75)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func blockColor(_ m: MeetingEvent) -> Color {
        if let rt = recordingTitle, m.title == rt { return .red }
        if m.id == nextID { return accent }
        return Color.secondary.opacity(0.55)
    }
}


/// Separate keys per list: both would otherwise merge into one value if SwiftUI ever
/// keeps two tabs alive at once.
private struct EventsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TasksHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
