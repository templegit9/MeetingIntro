import AppKit
import Combine
import SwiftUI

/// Meeting state in the menu bar, in its **own** status item (#26, #27, #30).
///
/// ## Why this is not a badge on the app icon
///
/// All three issues asked for the app icon to change — colour or a badge as a meeting
/// approaches, orange once you're late. That is precisely what `menuBarLabel` used to do
/// and what was deliberately removed in v2.15.2, on the maintainer's report that a
/// changing icon was hard to find in the menu bar. Recording, reminders-muted and
/// overdue-task glyph swaps were all built and then reverted for the same reason.
///
/// So the icon keeps its one permitted variation (the green update checkmark) and stays
/// where the eye expects it, and meeting state goes into a **separate, transient item**
/// that appears only when there is something to say and removes itself when there
/// isn't. `MenuBarCountdownModel` already establishes exactly this pattern for armed
/// auto-joins, so it is a shape the app has shipped, not a new idea.
///
/// The net effect is what was actually asked for — meeting state visible without
/// opening anything — with the stable icon left intact.
///
/// **Off by default.** The steady menu bar remains what everyone gets until they ask
/// for this.
@MainActor
final class MeetingStatusItem: NSObject, ObservableObject {

    static let enabledKey = "menuBarMeetingStatusEnabled"
    static let leadKey = "menuBarMeetingStatusLeadMinutes"
    static let lateKey = "menuBarMeetingStatusLateMinutes"

    /// How early the item appears. Jon's example was 15 minutes.
    static var leadMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: leadKey)
        return v > 0 ? v : 15
    }

    /// How long "late" keeps showing after start. His example was 10 minutes. Bounded
    /// because a stale LATE badge on a meeting you're actually sitting in is noise, and
    /// noise gets the whole feature switched off.
    static var lateMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: lateKey)
        return v > 0 ? v : 10
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private weak var calendarManager: CalendarManager?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// The meeting currently displayed, so the click menu can act on it.
    private var shown: MeetingEvent?

    func attach(calendarManager: CalendarManager, diagnosticLog: DiagnosticLog? = nil) {
        self.calendarManager = calendarManager
        self.diagnosticLog = diagnosticLog
        // **Subscribe to upcomingWeek, NOT todaysMeetings.** `todaysMeetings` is built
        // from the *reminder window* (`allEvents.filter { $0.startDate <= reminderWindowEnd }`),
        // so with a 15-minute largest threshold it simply does not contain a meeting
        // 45 minutes out — and this feature's lead can be up to 60. Reading it made the
        // item silently never appear for any lead wider than the reminder window.
        calendarManager.$upcomingWeek
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        diagnosticLog?.info(.calendar, "Meeting status item attached — enabled=\(Self.isEnabled) lead=\(Self.leadMinutes)m late=\(Self.lateMinutes)m")
        refresh()
    }

    private weak var diagnosticLog: DiagnosticLog?
    /// Last thing we displayed, so the log records transitions rather than every tick.
    private var lastLabel: String?

    /// Called when the setting changes so the item appears or disappears immediately
    /// rather than at the next tick.
    func settingsChanged() { refresh() }

    // MARK: - What to show

    /// The state worth surfacing right now, or nil for "say nothing".
    private func currentState() -> (meeting: MeetingEvent, text: String, late: Bool)? {
        guard Self.isEnabled, let manager = calendarManager else { return nil }
        let now = Date()

        // Today's meetings taken from the browse window, which actually spans the day.
        let today = manager.upcomingWeek
            .filter { Calendar.current.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }

        // Late beats upcoming: if you're already missing one, the next one can wait.
        let lateWindow = TimeInterval(Self.lateMinutes * 60)
        let late = today.first { m in
            !m.isCancelled
                && !m.isAllDay
                && m.startDate <= now
                && now < m.startDate.addingTimeInterval(lateWindow)
                && now < m.endDate
                && !manager.hasJoined(m.id)
        }
        if let late {
            let mins = max(1, Int(now.timeIntervalSince(late.startDate) / 60))
            return (late, "Late \(mins)m", true)
        }

        let leadWindow = TimeInterval(Self.leadMinutes * 60)
        let soon = today
            .filter { !$0.isCancelled && !$0.isAllDay && $0.startDate > now
                      && $0.startDate.timeIntervalSince(now) <= leadWindow }
            .min { $0.startDate < $1.startDate }
        if let soon {
            let mins = max(1, Int(soon.startDate.timeIntervalSince(now) / 60))
            return (soon, "in \(mins)m", false)
        }
        return nil
    }

    // MARK: - Lifecycle

    func refresh() {
        guard let state = currentState() else {
            if lastLabel != nil {
                diagnosticLog?.debug(.calendar, "Meeting status item hidden — nothing within \(Self.leadMinutes)m")
                lastLabel = nil
            }
            shown = nil
            stopTicking()
            removeStatusItem()
            return
        }
        shown = state.meeting
        installStatusItem()
        update(state)
        startTicking()
        let label = "\(state.text) · \(state.meeting.title)"
        if label != lastLabel {
            diagnosticLog?.info(.calendar, "Meeting status item showing — \(label)")
            lastLabel = label
        }
    }

    /// Ticks every 15s, not every second: this shows whole minutes, so a per-second
    /// timer would redraw the same string fourteen times out of fifteen. Only runs
    /// while something is displayed.
    private func startTicking() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func update(_ state: (meeting: MeetingEvent, text: String, late: Bool)) {
        guard let button = statusItem?.button else { return }
        let symbol = state.late ? "exclamationmark.circle.fill" : "calendar"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: state.text)
        // Not a template image when late: orange is the signal Jon asked for, and a
        // template would be flattened to monochrome by the menu bar.
        img?.isTemplate = !state.late
        button.image = img
        button.imagePosition = .imageLeading

        // Title first, then the time: the meeting is the subject and the countdown is
        // what's happening to it, which is the order you'd say it out loud. The title is
        // truncated rather than omitted — the menu bar is shared real estate, and an
        // item that grows to fit a long meeting name shoves everyone else along.
        let label = " \(Self.shortTitle(state.meeting.title)) · \(state.text)"
        if state.late {
            button.attributedTitle = NSAttributedString(
                string: label,
                attributes: [.foregroundColor: NSColor.systemOrange]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: label)
        }
        // The tooltip carries the untruncated title, so the full name is always one
        // hover away.
        button.toolTip = "\(state.meeting.title) · \(state.meeting.formattedStartTime)"
    }

    /// Caps the title so the item stays a reasonable width. Truncates on a word
    /// boundary where it can, so "Quarterly Roadmap Rev…" beats "Quarterly Roadmap R…".
    static func shortTitle(_ title: String, max: Int = 22) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        let cut = String(trimmed.prefix(max))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > max / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    private func removeStatusItem() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }
}

// MARK: - Click menu

extension MeetingStatusItem: NSMenuDelegate {

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in rebuild(menu) }
    }

    @MainActor
    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let meeting = shown else { return }

        let header = NSMenuItem(title: meeting.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let when = NSMenuItem(title: meeting.formattedStartTime, action: nil, keyEquivalent: "")
        when.isEnabled = false
        menu.addItem(when)
        menu.addItem(.separator())

        if meeting.url != nil {
            let join = NSMenuItem(title: "Join Now", action: #selector(joinNow), keyEquivalent: "")
            join.target = self
            menu.addItem(join)
        }
        if MeetingClipboard.has(.link, meeting) {
            let copy = NSMenuItem(title: "Copy Join Link", action: #selector(copyLink), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
    }

    @MainActor @objc private func joinNow() {
        guard let url = shown?.url else { return }
        NSWorkspace.shared.open(url)
        // Opening from here counts as joining, so the late badge clears instead of
        // nagging about a meeting you just walked into.
        if let id = shown?.id { calendarManager?.markJoined(id) }
        refresh()
    }

    @MainActor @objc private func copyLink() {
        guard let meeting = shown else { return }
        MeetingClipboard.copy(.link, of: meeting)
    }
}
