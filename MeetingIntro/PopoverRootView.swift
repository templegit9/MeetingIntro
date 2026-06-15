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
    @ObservedObject var quickAddPanel: QuickAddPanelController
    @ObservedObject var updater: AppUpdater

    @Environment(\.openWindow) private var openWindow
    @AppStorage("cancellationShowInTodayView") private var showCancelled: Bool = true
    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex

    private enum Tab { case today, upcoming }
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tab == .upcoming { dayPager; Divider() }
            eventsList
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            segment("Today", isOn: tab == .today) { tab = .today }
            segment("Upcoming", isOn: tab == .upcoming) { tab = .upcoming }
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
                .frame(maxHeight: 300)
            }
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
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "video.fill").foregroundStyle(.green) }
                    .buttonStyle(.borderless).help("Join")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow("New Event…", "plus", "⌘N") { quickAddPanel.show() }
            footerRow("Meeting Notes…", "note.text", "⌘M") { openWindow(id: "meetingNotes"); NSApp.activate(ignoringOtherApps: true) }
            SettingsLink { footerLabel("Settings…", "gearshape", "⌘,") }.buttonStyle(.plain)
            footerRow("Quit MeetingIntro", "power", "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 4)
    }

    private func footerRow(_ label: String, _ symbol: String, _ shortcut: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { footerLabel(label, symbol, shortcut) }.buttonStyle(.plain)
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
