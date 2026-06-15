import Foundation

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
