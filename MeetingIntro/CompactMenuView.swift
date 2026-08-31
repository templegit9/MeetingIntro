import AppKit
import SwiftUI

/// The default menu-bar dropdown content, rendered in a `.window`-style `MenuBarExtra`
/// popover (we can't use `.menu` anymore — it can't coexist with the rich popover, and
/// SceneBuilder can't switch styles). This is a clean SwiftUI port of the former native
/// menu: update banner, recording, cancellations, armed auto-join, today's meetings with
/// inline RSVP, an Upcoming submenu, and the action rows. Functional parity with the old
/// NSMenu; the rich `PopoverRootView` is the alternate presentation (Phase 2+).
struct CompactMenuView: View {
    @ObservedObject var calendarManager: CalendarManager
    @ObservedObject var recordingController: RecordingController
    @ObservedObject var recordingCoordinator: MeetingRecordingCoordinator
    @ObservedObject var updater: AppUpdater
    @ObservedObject var smartConfig: SmartConfigManager
    @ObservedObject var contextMonitor: MeetingContextMonitor
    @ObservedObject var quickAddService: QuickAddService
    @ObservedObject var quickAddConfig: QuickAddConfig
    @ObservedObject var taskManager: TaskManager

    /// #13 focus spike: an inline compact New Event form embedded in the dropdown.
    @State private var showingNewEvent = false
    @State private var creatingEvent = false
    @FocusState private var newEventFocused: Bool

    @Environment(\.openWindow) private var openWindow
    @AppStorage("cancellationShowInTodayView") private var showCancelled: Bool = true
    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex

    /// Hover-to-detail (Issue #16): `hoveredID` drives the popover; `pendingHoverID`
    /// gates a short show-delay so brushing across rows doesn't flicker cards.
    @State private var hoveredID: String?
    @State private var pendingHoverID: String?

    private var accent: Color { Color(hex: nextMeetingHighlightHex) }

    private var todays: [MeetingEvent] {
        showCancelled ? calendarManager.todaysMeetings : calendarManager.todaysMeetings.filter { !$0.isCancelled }
    }

    /// #13 focus spike: a compact New Event form inside the dropdown popover. The open
    /// question is whether the `.window` MenuBarExtra reliably first-responds this field.
    private var newEventForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { showingNewEvent = false; quickAddService.reset() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text(quickAddService.draft?.kind == .task ? "New Task" : "New Event").font(.headline)
                Spacer()
            }
            TextField("Lunch with Sam tomorrow 1pm  ·  Submit report by Fri 5pm", text: $quickAddService.inputText)
                .textFieldStyle(.roundedBorder)
                .focused($newEventFocused)
                .onSubmit { create() }
            if let draft = quickAddService.draft {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { draft.kind }, set: { quickAddService.kindOverride = $0 })) {
                        Text("Event").tag(DraftKind.event)
                        Text("Task").tag(DraftKind.task)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(draft.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text((draft.kind == .task ? "Due " : "") + draft.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.kind == .event {
                        newEventLinkControl(draft)
                        // Same honesty as the popover: only Microsoft 365 can send the
                        // invitations, so never let a typed address vanish quietly.
                        if !draft.attendees.isEmpty {
                            let canInvite = calendarManager.eventCreationProvider == .microsoftGraph
                            Label(canInvite
                                  ? "Inviting \(draft.attendees.joined(separator: ", "))"
                                  : "\(draft.attendees.count) invitee\(draft.attendees.count == 1 ? "" : "s") won't be invited — macOS Calendar can't send invitations.",
                                  systemImage: canInvite ? "person.crop.circle.badge.plus" : "person.crop.circle.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(canInvite ? Color.secondary : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !quickAddService.conflicts.isEmpty {
                            Label("Overlaps “\(quickAddService.conflicts[0])”" + (quickAddService.conflicts.count > 1 ? " + \(quickAddService.conflicts.count - 1) more" : ""),
                                  systemImage: "calendar.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
            } else if !quickAddService.inputText.isEmpty {
                Text(quickAddService.isParsing ? "Parsing…" : "Keep typing…")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button(creatingEvent ? "Creating…" : "Create") { create() }
                    .disabled(quickAddService.draft == nil || creatingEvent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onAppear { newEventFocused = true }
        .onExitCommand { showingNewEvent = false; quickAddService.reset() }
    }

    private func create() {
        guard let draft = quickAddService.draft, !creatingEvent else { return }
        creatingEvent = true
        Task {
            if draft.kind == .task {
                taskManager.add(taskManager.makeTask(title: draft.title, dueDate: draft.startDate, notes: draft.notes))
            } else {
                try? await calendarManager.createEvent(from: draft, calendarID: quickAddConfig.defaultCalendarID)
            }
            creatingEvent = false
            showingNewEvent = false
            quickAddService.reset()
        }
    }

    /// Meeting-link attach/switch/remove (mirrors QuickAddView.linkControl).
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

    var body: some View {
        if showingNewEvent {
            newEventForm
        } else {
            menuBody
        }
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if case .available(let v) = updater.state {
                actionRow(icon: "arrow.down.circle.fill", tint: accent,
                          label: "Update available — install v\(v)", bold: true) {
                    Task { await updater.update() }
                }
                Divider()
            }

            if recordingController.isRecording, let title = recordingController.currentMeetingTitle {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Recording — \(title)").font(.caption.weight(.semibold)).foregroundStyle(.red).lineLimit(1)
                    Spacer()
                    Button("Stop") { Task { await recordingCoordinator.stopManually() } }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }

            if smartConfig.suppressWhenInCall && contextMonitor.snapshot.isInActiveCall {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    Text("Reminders paused — you're on a call").font(.caption.weight(.semibold)).foregroundStyle(.orange).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
            }

            if !calendarManager.pendingCancellations.isEmpty {
                sectionHeader("Cancelled — click to dismiss", color: .orange)
                ForEach(calendarManager.pendingCancellations) { m in
                    glyphRow(icon: "xmark.circle.fill", tint: .red, time: m.formattedStartTime, title: m.title) {
                        calendarManager.dismissCancellation(m.id)
                    }
                }
                Divider()
            }

            if !calendarManager.armedAutoJoinMeetings.isEmpty {
                sectionHeader("Auto-join armed — click to cancel", color: accent)
                ForEach(calendarManager.armedAutoJoinMeetings) { m in
                    glyphRow(icon: "clock.badge.checkmark", tint: accent, time: m.formattedStartTime, title: m.title) {
                        calendarManager.disarmAutoJoin(m.id)
                    }
                }
                Divider()
            }

            // Tasks due soon (Issue #19)
            let dueSoon = taskManager.dueSoon()
            if !dueSoon.isEmpty {
                sectionHeader("Tasks due soon — click to complete", color: .orange)
                ForEach(dueSoon) { task in
                    glyphRow(icon: "circle", tint: .orange, time: task.dueLabel, title: task.title) {
                        taskManager.complete(task.id)
                    }
                }
                Divider()
            }

            // Today
            sectionHeader("Today's Meetings", color: .secondary)
            if todays.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "calendar"); Text("No meetings today")
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(todays) { eventRow($0) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
                .scrollBounceBehavior(.basedOnSize)
            }

            // Upcoming days — a popup Menu listing future days (compact label: header · count)
            let schedules = calendarManager.upcomingDaySchedules()
            if !schedules.isEmpty {
                Divider()
                Menu {
                    ForEach(schedules, id: \.date) { day in
                        Section("\(UpcomingDayFormat.header(for: day.date)) · \(day.events.count)") {
                            ForEach(day.events.prefix(10)) { m in
                                Button {
                                    if let url = m.url { NSWorkspace.shared.open(url) }
                                } label: {
                                    Text("\(m.formattedStartTime)  \(m.title)")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Upcoming", systemImage: "calendar.badge.clock")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if let error = calendarManager.errorMessage {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            Divider()
            actionRow(icon: "plus", tint: .primary, label: "New Event", trailing: "⌘N") {
                quickAddService.reset()
                showingNewEvent = true
            }
            actionRow(icon: "note.text", tint: .primary, label: "Meeting Notes", trailing: "⌘M") {
                openWindow(id: "meetingNotes"); NSApp.activate(ignoringOtherApps: true)
            }
            actionRow(icon: "arrow.clockwise", tint: .primary, label: "Refresh", trailing: "⌘R") {
                Task { await calendarManager.refreshEvents() }
            }
            SettingsLink { actionLabel(icon: "gearshape", tint: .primary, label: "Settings", trailing: "⌘,") }
                .buttonStyle(.plain)
            actionRow(icon: "power", tint: .primary, label: "Quit MeetingIntro", trailing: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }

    // MARK: - Rows

    private func sectionHeader(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.4)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
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
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill").foregroundStyle(.green)
                }
                .buttonStyle(.borderless).help("Join")
            }
            if !meeting.isCancelled {
                Menu {
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

    private func glyphRow(icon: String, tint: Color, time: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.caption)
                Text(time).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(title).font(.body).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 3)
    }

    private func actionRow(icon: String, tint: Color, label: String, trailing: String? = nil, bold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon: icon, tint: tint, label: label, trailing: trailing, bold: bold) }
            .buttonStyle(.plain)
    }

    private func actionLabel(icon: String, tint: Color, label: String, trailing: String? = nil, bold: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(tint == .primary ? .secondary : tint)
            Text(label).font(bold ? .system(.body, weight: .semibold) : .body).foregroundStyle(tint == .primary ? .primary : tint)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}
