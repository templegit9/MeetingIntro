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
    @ObservedObject var quickAddPanel: QuickAddPanelController
    @ObservedObject var updater: AppUpdater

    @Environment(\.openWindow) private var openWindow
    @AppStorage("cancellationShowInTodayView") private var showCancelled: Bool = true
    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex
    @AppStorage(UpcomingViewStyle.storageKey) private var upcomingViewStyleRaw: String = UpcomingViewStyle.off.rawValue
    @AppStorage(UpcomingDayLabelFormat.storageKey) private var dayLabelFormatRaw: String = UpcomingDayLabelFormat.compact.rawValue
    @AppStorage(UpcomingDayLabelFormat.showCountKey) private var upcomingShowCount: Bool = true

    private var accent: Color { Color(hex: nextMeetingHighlightHex) }
    private var dayLabelFormat: UpcomingDayLabelFormat { UpcomingDayLabelFormat(rawValue: dayLabelFormatRaw) ?? .compact }
    private var upcomingStyle: UpcomingViewStyle { UpcomingViewStyle(rawValue: upcomingViewStyleRaw) ?? .off }

    private var todays: [MeetingEvent] {
        showCancelled ? calendarManager.todaysMeetings : calendarManager.todaysMeetings.filter { !$0.isCancelled }
    }

    var body: some View {
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
                .frame(maxHeight: 280)
            }

            // Upcoming (reuses the day grouping; a popup Menu listing future days)
            if upcomingStyle != .off {
                let schedules = calendarManager.upcomingDaySchedules()
                if !schedules.isEmpty {
                    Divider()
                    Menu {
                        ForEach(schedules, id: \.date) { day in
                            Section(dayLabelFormat.label(date: day.date, count: day.events.count, showCount: upcomingShowCount)) {
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
            actionRow(icon: "plus", tint: .primary, label: "New Event…", trailing: "⌘N") { quickAddPanel.show() }
            actionRow(icon: "note.text", tint: .primary, label: "Meeting Notes…", trailing: "⌘M") {
                openWindow(id: "meetingNotes"); NSApp.activate(ignoringOtherApps: true)
            }
            actionRow(icon: "arrow.clockwise", tint: .primary, label: "Refresh", trailing: "⌘R") {
                Task { await calendarManager.refreshEvents() }
            }
            SettingsLink { actionLabel(icon: "gearshape", tint: .primary, label: "Settings…", trailing: "⌘,") }
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
                .frame(width: 58, alignment: .leading)
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
            if calendarManager.supportsRSVPWrite, !meeting.isCancelled,
               [.accepted, .declined, .tentative, .noResponse].contains(meeting.myResponse) {
                Menu {
                    Button("Accept") { Task { try? await calendarManager.respond(to: meeting.id, status: .accepted) } }
                    Button("Tentative") { Task { try? await calendarManager.respond(to: meeting.id, status: .tentative) } }
                    Button("Decline") { Task { try? await calendarManager.respond(to: meeting.id, status: .declined) } }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func glyphRow(icon: String, tint: Color, time: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.caption)
                Text(time).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
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
