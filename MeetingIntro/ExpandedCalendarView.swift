import SwiftUI

/// The expanded calendar (#32) — the popover's second gear.
///
/// The collapsed panel answers "what's next?" well, but it is also the only door into
/// the app, so anything needing context ("is Thursday free?", "when did that offsite
/// land?") pushed the user out to Calendar.app. This grows the same popover in place
/// rather than opening a window: a window would have to be managed — minimised, hidden,
/// forgotten — and having nothing to manage is the point of a menu bar app.
///
/// ## Opened by keyboard and by a control, deliberately not by double-click
///
/// The original concept was double-clicking the menu bar icon. **That gesture is not
/// available**: the panel is a SwiftUI `MenuBarExtra` in `.window` style, which consumes
/// the click itself to open its popover, and SwiftUI exposes no way to see a second one.
/// Reaching it would mean replacing `MenuBarExtra` with a hand-built `NSStatusItem` —
/// and a hand-built status item cannot reliably open the SwiftUI `Settings` scene (the
/// v2.7.1 failure; `SettingsLink` is SwiftUI-only), which this view's rail needs.
///
/// So entry is `⌘⇧C` and the expand control in the panel header. Both were in the design
/// anyway; the gesture can be added later if `MenuBarExtra` is ever unpicked.
///
/// ## Two columns, because two jobs are wanted at once
///
/// The grid answers *when*. The rail keeps the collapsed panel's job alive — today's
/// status and the next three events — so expanding never costs you the thing you opened
/// the panel for.
struct ExpandedCalendarView: View {

    @ObservedObject var calendarManager: CalendarManager
    @ObservedObject var taskManager: TaskManager
    let accent: Color
    /// Collapse back to the small panel.
    let onCollapse: () -> Void
    let onNewEvent: () -> Void

    enum Mode: String, CaseIterable {
        case month, week, day
        var label: String { rawValue.capitalized }
    }

    /// The last view is remembered; **the expanded state itself is not** — a single
    /// click must always be the fast glance, never a full calendar you have to dismiss.
    @AppStorage("expandedCalendarMode") private var modeRaw: String = Mode.month.rawValue
    @State private var anchor = Date()
    @State private var selected = Date()

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .month }
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                agendaRail
                    .frame(width: 300)
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 580)
        .task { await calendarManager.loadBrowseWindow() }
        .onExitCommand(perform: onCollapse)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(titleForAnchor)
                .font(.system(size: 15, weight: .semibold))
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Button("Today") { anchor = Date(); selected = Date() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(accent)

            Spacer()

            Picker("", selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue })) {
                ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            if calendarManager.isLoadingBrowse {
                ProgressView().controlSize(.small)
            }

            Button {
                onCollapse()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderless)
            .help("Collapse (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var titleForAnchor: String {
        let f = DateFormatter()
        switch mode {
        case .month: f.dateFormat = "MMMM yyyy"
        case .week:  f.dateFormat = "MMMM yyyy"
        case .day:   f.dateFormat = "EEEE d MMMM"
        }
        return f.string(from: anchor)
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : (mode == .week ? .weekOfYear : .day)
        if let next = cal.date(byAdding: component, value: direction, to: anchor) {
            anchor = next
            if mode == .day { selected = next }
        }
    }

    // MARK: - Grid

    @ViewBuilder private var grid: some View {
        switch mode {
        case .month: monthGrid
        case .week:  weekGrid
        case .day:   dayList
        }
    }

    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        let syms = f.shortStandaloneWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        // Rotate so the row starts on the locale's first weekday.
        let first = cal.firstWeekday - 1
        return Array(syms[first...] + syms[..<first]).map { $0.uppercased() }
    }

    private var monthGrid: some View {
        VStack(spacing: 0) {
            weekdayHeader
            let days = monthDays
            let rows = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { day in
                            dayCell(day, maxChips: 3)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var weekGrid: some View {
        VStack(spacing: 0) {
            weekdayHeader
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { day in
                    dayCell(day, maxChips: 10)
                }
            }
        }
    }

    private var dayList: some View {
        let events = calendarManager.browseEvents(on: anchor)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if events.isEmpty {
                    Text("Nothing scheduled")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    ForEach(events) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(e.formattedStartTime)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                            Rectangle().fill(color(for: e)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title)
                                    .fontWeight(.medium)
                                    .strikethrough(e.isCancelled)
                                if let loc = e.location, !loc.isEmpty {
                                    Text(loc).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let url = e.url {
                                Button("Join") {
                                    calendarManager.markJoined(e.id)
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding(14)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { s in
                Text(s)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private func dayCell(_ day: Date, maxChips: Int) -> some View {
        let events = calendarManager.browseEvents(on: day)
        let isToday = cal.isDateInToday(day)
        let inAnchorMonth = mode != .month || cal.isDate(day, equalTo: anchor, toGranularity: .month)
        let isSelected = cal.isDate(day, inSameDayAs: selected)

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : (inAnchorMonth ? .primary : .secondary))
                    .padding(.horizontal, isToday ? 5 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background(isToday ? accent : .clear, in: Capsule())
                Spacer()
            }
            ForEach(events.prefix(maxChips)) { e in
                chip(e)
            }
            if events.count > maxChips {
                Text("+\(events.count - maxChips) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? accent.opacity(0.10) : .clear)
        .overlay(alignment: .leading) { Divider() }
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { selected = day }
        .opacity(inAnchorMonth ? 1 : 0.45)
    }

    /// Event chips carry the calendar's colour so shape and source are legible without
    /// reading every title.
    private func chip(_ e: MeetingEvent) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color(for: e)).frame(width: 2.5)
            Text(e.isAllDay ? e.title : "\(e.formattedStartTime) \(e.title)")
                .font(.system(size: 9.5))
                .lineLimit(1)
                .strikethrough(e.isCancelled)
                .foregroundStyle(e.isCancelled ? .secondary : .primary)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 2)
        .background(color(for: e).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }

    /// Derived from the calendar name so the same calendar is always the same colour,
    /// without needing EventKit's own colour above the provider boundary — `MeetingEvent`
    /// deliberately doesn't carry one.
    private func color(for e: MeetingEvent) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .brown, .mint]
        var hash = 5381
        for b in e.calendarName.utf8 { hash = (hash &* 33) &+ Int(b) }
        return palette[abs(hash) % palette.count]
    }

    private var monthDays: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: anchor) else { return [] }
        let firstWeek = cal.dateInterval(of: .weekOfMonth, for: interval.start)?.start ?? interval.start
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: firstWeek) }
    }

    private var weekDays: [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: - Agenda rail

    private var agendaRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        Text("NOW · \(Date().formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                let dayEvents = calendarManager.browseEvents(on: selected)
                VStack(alignment: .leading, spacing: 4) {
                    if dayEvents.isEmpty {
                        Text("No meetings")
                            .font(.system(size: 13, weight: .semibold))
                        if let next = nextUp.first {
                            Text("Next is \(next.startDate.formatted(.relative(presentation: .named))) — \(next.title).")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("\(dayEvents.count) meeting\(dayEvents.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))

                if !nextUp.isEmpty {
                    Text("NEXT UP")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    ForEach(nextUp) { e in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.startDate.formatted(.dateTime.weekday(.abbreviated)))
                                Text(e.formattedStartTime)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                            Rectangle().fill(color(for: e)).frame(width: 2.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(subtitle(for: e)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Divider()

                // Same actions, same order, same shortcuts as the collapsed panel's
                // footer, so nothing has to be relearned when the panel grows.
                VStack(spacing: 0) {
                    railAction("New Event", "⌘N") { onNewEvent() }
                    SettingsLink {
                        railActionLabel("Settings", "⌘,")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    private var nextUp: [MeetingEvent] {
        let source = calendarManager.browseEvents.isEmpty ? calendarManager.upcomingWeek : calendarManager.browseEvents
        return source
            .filter { $0.startDate > Date() && !$0.isCancelled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { $0 }
    }

    private func subtitle(for e: MeetingEvent) -> String {
        var parts: [String] = []
        if e.attendeeCount > 0 { parts.append("\(e.attendeeCount) guest\(e.attendeeCount == 1 ? "" : "s")") }
        if let loc = e.location, !loc.isEmpty { parts.append(loc) }
        if parts.isEmpty { parts.append(e.calendarName) }
        return parts.joined(separator: " · ")
    }

    private func railAction(_ title: String, _ shortcut: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { railActionLabel(title, shortcut) }
            .buttonStyle(.plain)
    }

    private func railActionLabel(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint("←→", "day")
            hint("⇧←→", mode == .month ? "month" : "week")
            Spacer()
            Text("esc to shrink back")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, design: .monospaced))
            Text(what).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
