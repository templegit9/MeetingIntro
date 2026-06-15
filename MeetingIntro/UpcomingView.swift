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
