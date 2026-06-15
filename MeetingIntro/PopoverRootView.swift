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
    @ObservedObject var diagnosticLog: DiagnosticLog

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
            eventsList
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
            || calendarManager.errorMessage != nil
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.state { return true }
        return false
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
    }

    private func calloutCard(icon: String, tint: Color, title: String, actionLabel: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 20)
            Text(title).font(.system(.caption, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 4)
            Button(actionLabel, action: action).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).buttonStyle(.borderless)
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
