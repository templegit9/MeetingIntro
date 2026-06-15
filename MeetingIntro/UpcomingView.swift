import Foundation

/// How future-date events are surfaced from the menu bar. User-selectable in Settings.
enum UpcomingViewStyle: String, CaseIterable, Identifiable {
    /// Only today's meetings (the original behavior).
    case off
    /// A single "Upcoming ›" submenu, future days grouped under dated subheaders.
    case upcomingSubmenu
    /// One "‹day› ›" submenu per future day.
    case perDay
    /// Replace the whole dropdown with a popover that pages day-by-day (‹ / ›).
    case popover

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Today only"
        case .upcomingSubmenu: return "Upcoming ▸ submenu"
        case .perDay: return "Per-day submenus"
        case .popover: return "Day browser popover"
        }
    }

    var detail: String {
        switch self {
        case .off: return "The dropdown shows today's meetings only."
        case .upcomingSubmenu: return "Adds one \"Upcoming ▸\" item; hover to see future days grouped by date."
        case .perDay: return "Adds a \"▸\" submenu per future day to drill into each."
        case .popover: return "Adds a \"Browse Upcoming Days…\" item that opens a floating popover you can page through with ‹ / ›."
        }
    }

    static let storageKey = "upcomingViewStyle"
}

/// How the menu-bar dropdown is presented. Both are SwiftUI views in a `.window`
/// MenuBarExtra (the native NSMenu was retired — see docs/popover-redesign-spec.md).
enum MenuBarPresentation: String, CaseIterable, Identifiable {
    case menu      // compact, menu-styled list (CompactMenuView)
    case popover   // rich CodexBar-style popover (PopoverRootView) — default (v2.9.0)

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .menu: return "Compact menu"
        case .popover: return "Rich popover"
        }
    }
    static let storageKey = "menuBarPresentation"
}

/// How a day's row is labelled in the upcoming submenus (user-selectable).
enum UpcomingDayLabelFormat: String, CaseIterable, Identifiable {
    case compact     // "Tomorrow · 7"
    case verbose     // "Tomorrow — 7 meetings"
    case weekday     // "Tuesday · 7"  (full weekday, no date)
    case dateFirst   // "Jun 16 · Tue · 7"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact (Tomorrow · 7)"
        case .verbose: return "Verbose (Tomorrow — 7 meetings)"
        case .weekday: return "Weekday (Tuesday · 7)"
        case .dateFirst: return "Date first (Jun 16 · Tue · 7)"
        }
    }

    /// Build the row label for a day.
    func label(date: Date, count: Int, showCount: Bool) -> String {
        let countSuffix: String
        switch self {
        case .verbose:
            countSuffix = showCount ? " — \(count) meeting\(count == 1 ? "" : "s")" : ""
        default:
            countSuffix = showCount ? " · \(count)" : ""
        }
        switch self {
        case .compact, .verbose:
            return UpcomingDayFormat.header(for: date) + countSuffix
        case .weekday:
            return UpcomingDayFormat.fullWeekday(for: date) + countSuffix
        case .dateFirst:
            return "\(UpcomingDayFormat.monthDay(for: date)) · \(UpcomingDayFormat.weekdayAbbr(for: date))" + countSuffix
        }
    }

    static let storageKey = "upcomingDayLabelFormat"
    static let showCountKey = "upcomingShowCount"
}

/// Shared day-header formatting for the upcoming views ("Today" / "Tomorrow" / "Wed Jun 18").
enum UpcomingDayFormat {
    static func header(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        // e.g. "Wed Jun 18"
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f.string(from: date)
    }

    /// Full weekday, with relative names ("Today" / "Tomorrow" / "Tuesday").
    static func fullWeekday(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: date)
    }

    /// "Jun 16"
    static func monthDay(for date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: date)
    }

    /// "Tue"
    static func weekdayAbbr(for date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date)
    }

    /// Longer header for the popover ("Today · Wed Jun 18").
    static func longHeader(for date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE MMM d")
        let base = f.string(from: date)
        if cal.isDateInToday(date) { return "Today · \(base)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow · \(base)" }
        return base
    }
}
