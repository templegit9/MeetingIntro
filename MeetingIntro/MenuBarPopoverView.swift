import AppKit
import SwiftUI

/// A floating popover that pages through upcoming days with ‹ / ›. Used by the
/// "Day-by-day popover" Upcoming-events style — opened from a menu item rather than
/// replacing the whole dropdown (MenuBarExtra can't switch between .menu and .window
/// styles at runtime, so a true dropdown-popover would require dropping MenuBarExtra).
struct UpcomingDaysPanelView: View {
    @ObservedObject var calendarManager: CalendarManager
    var onClose: () -> Void = {}

    @AppStorage("cancellationShowInTodayView") private var showCancelled: Bool = true
    @AppStorage("nextMeetingHighlightHex") private var nextMeetingHighlightHex: String = defaultNextMeetingHighlightHex

    @State private var dayOffset = 0

    private var horizon: Int { calendarManager.upcomingDaysAhead }

    private var selectedDay: Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private var dayEvents: [MeetingEvent] {
        let evts = calendarManager.events(on: selectedDay)
        return showCancelled ? evts : evts.filter { !$0.isCancelled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Upcoming").font(.headline)
                Spacer()
                Button { Task { await calendarManager.refreshEvents() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            Divider()
            dayNavigator
            Divider()
            eventsList
        }
        .frame(width: 360, height: 420)
    }

    private var dayNavigator: some View {
        HStack(spacing: 8) {
            Button { if dayOffset > 0 { dayOffset -= 1 } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(dayOffset <= 0)
            Spacer()
            Text(UpcomingDayFormat.longHeader(for: selectedDay))
                .font(.system(.subheadline, weight: .semibold))
            Spacer()
            Button { if dayOffset < horizon { dayOffset += 1 } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(dayOffset >= horizon)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var eventsList: some View {
        Group {
            if dayEvents.isEmpty {
                VStack {
                    Spacer()
                    HStack { Image(systemName: "calendar"); Text("No meetings") }
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(dayEvents) { eventRow($0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func eventRow(_ meeting: MeetingEvent) -> some View {
        let highlight = Color(hex: nextMeetingHighlightHex)
        let isNext = meeting.id == calendarManager.nextMeeting?.id
        return HStack(spacing: 8) {
            Text(meeting.formattedStartTime)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(isNext ? highlight : .secondary)
                .frame(width: 62, alignment: .leading)
            Text(meeting.title)
                .font(.body)
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
                .buttonStyle(.borderless)
                .help("Join")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contextMenu { rsvpMenu(meeting) }
    }

    @ViewBuilder
    private func rsvpMenu(_ meeting: MeetingEvent) -> some View {
        if calendarManager.supportsRSVPWrite, !meeting.isCancelled,
           [.accepted, .declined, .tentative, .noResponse].contains(meeting.myResponse) {
            Button("Accept") { Task { try? await calendarManager.respond(to: meeting.id, status: .accepted) } }
            Button("Tentative") { Task { try? await calendarManager.respond(to: meeting.id, status: .tentative) } }
            Button("Decline") { Task { try? await calendarManager.respond(to: meeting.id, status: .declined) } }
        }
    }
}

/// Hosts `UpcomingDaysPanelView` in a floating titled panel, opened from the menu.
@MainActor
final class UpcomingPanelController: ObservableObject {
    private var panel: NSPanel?

    func toggle(calendarManager: CalendarManager) {
        if panel != nil { close(); return }
        let view = UpcomingDaysPanelView(calendarManager: calendarManager, onClose: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        p.title = "Upcoming"
        p.contentView = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 440))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }

    func close() {
        panel?.close()
        panel = nil
    }
}
