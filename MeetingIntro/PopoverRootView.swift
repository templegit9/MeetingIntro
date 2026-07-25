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

    private enum Tab { case today, upcoming, tasks }
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
        if showingNewEvent {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { showingNewEvent = false; quickAddService.reset() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless).foregroundStyle(accent)
                Text(quickAddService.draft?.kind == .task ? "New Task" : "New Event").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            TextField("Lunch with Sam tomorrow 1pm  ·  Submit report by Fri 5pm", text: $quickAddService.inputText)
                .textFieldStyle(.roundedBorder)
                .focused($newEventFocused)
                .onSubmit { create() }

            if let draft = quickAddService.draft {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: Binding(get: { draft.kind }, set: { quickAddService.kindOverride = $0 })) {
                        Text("Event").tag(DraftKind.event)
                        Text("Task").tag(DraftKind.task)
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    Text(draft.title).font(.system(.callout, weight: .semibold)).lineLimit(1)
                    Label((draft.kind == .task ? "Due " : "") + draft.startDate.formatted(date: .abbreviated, time: .shortened),
                          systemImage: draft.kind == .task ? "checkmark.circle" : "clock")
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.kind == .task {
                        // Task detected — extra fields (notes + reminder) inline. Title + due
                        // come from the parsed text above; these are editable and persist.
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
                    if draft.kind == .event {
                        if let loc = draft.location, !loc.isEmpty {
                            Label(loc, systemImage: "location").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        newEventLinkControl(draft)
                    }
                    ForEach(draft.assumptions, id: \.self) { a in
                        Label(a, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if draft.kind == .event, !quickAddService.conflicts.isEmpty {
                        Label("Overlaps “\(quickAddService.conflicts[0])”" + (quickAddService.conflicts.count > 1 ? " + \(quickAddService.conflicts.count - 1) more" : ""),
                              systemImage: "calendar.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if !quickAddService.inputText.isEmpty {
                Text(quickAddService.isParsing ? "Parsing…" : "Keep typing…")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack {
                Text("↩ to create · esc to cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(creatingEvent ? "Creating…" : "Create") { create() }
                    .disabled(quickAddService.draft == nil || creatingEvent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onAppear { newEventFocused = true; newEventTask = TaskItem(title: "") }
        .onExitCommand { showingNewEvent = false; quickAddService.reset() }
    }

    private func create() {
        guard let draft = quickAddService.draft, !creatingEvent else { return }
        creatingEvent = true
        Task {
            if draft.kind == .task {
                var t = newEventTask
                t.title = draft.title
                t.dueDate = draft.startDate
                if t.notes == nil { t.notes = draft.notes }
                taskManager.add(t)
            } else {
                try? await calendarManager.createEvent(from: draft, calendarID: quickAddConfig.defaultCalendarID)
            }
            creatingEvent = false
            showingNewEvent = false
            quickAddService.reset()
        }
    }

    /// Meeting-link attach/switch/remove (mirrors QuickAddView.linkControl) so the
    /// embedded form has the same link affordance as the old floating panel.
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
            Text(syncedText)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Button { Task { await calendarManager.refreshEvents() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.borderless).help("Refresh").padding(.leading, 6)
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? accent : .secondary)
                .padding(.vertical, 5).padding(.horizontal, 12)
                .background(isOn ? accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var syncedText: String {
        guard let date = calendarManager.lastRefreshDate else { return "" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "synced just now" }
        if secs < 3600 { return "synced \(secs / 60)m ago" }
        return "synced \(secs / 3600)h ago"
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

    private var eventsList: some View {
        Group {
            if listEvents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 26, weight: .thin)).foregroundStyle(.tertiary)
                    Text(tab == .today ? "No meetings today" : "No meetings").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(listEvents) { eventRow($0) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 140, maxHeight: 300)
                .scrollBounceBehavior(.basedOnSize)
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(taskManager.sorted) { taskRow($0) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 120, maxHeight: 300)
                .scrollBounceBehavior(.basedOnSize)
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
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "video.fill").foregroundStyle(.green) }
                    .buttonStyle(.borderless).help("Join")
            }
            if !meeting.isCancelled {
                Menu {
                    if calendarManager.supportsRSVPWrite,
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
