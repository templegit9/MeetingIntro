import Foundation

/// How loudly Margin may speak about something it noticed.
///
/// Straight from the spec, and the ordering is the whole point: **most of what it notices
/// is only ever a tick on today's page.** A nudge system without a ceiling becomes Clippy,
/// which died of unsolicited interruption with no memory of being dismissed.
enum MarginVolume: String, Codable, CaseIterable {
    /// Done and logged. Reversible, low stakes, nobody else affected.
    case tickedSilently
    /// Marked and waiting. You find it next time you open the notebook.
    case ribbonOnly
    /// A page shows itself — at most three a day, and only in a gap.
    case foldedCorner
    /// Only if the option dies in minutes. Not used by any v1 watch.
    case opensItself

    var label: String {
        switch self {
        case .tickedSilently: return "Ticked silently"
        case .ribbonOnly:     return "Ribbon only"
        case .foldedCorner:   return "Folded corner"
        case .opensItself:    return "Opens itself"
        }
    }
}

/// Where a watch came from. Shown on the inside-cover list, because **nothing may appear
/// from nowhere** — a watch you can't account for is one you can't trust.
enum WatchOrigin: String, Codable {
    case builtIn
    case youAsked
    case learned

    var label: String {
        switch self {
        case .builtIn:  return "default"
        case .youAsked: return "you asked for this"
        case .learned:  return "learned from your corrections"
        }
    }
}

/// One standing watch. State is small and persisted, because decay only means anything if
/// the notebook remembers being ignored.
struct WatchState: Codable, Identifiable, Equatable {
    let id: String
    var label: String
    var origin: WatchOrigin
    var enabled: Bool = true
    /// Times a page from this watch was ignored or dismissed. **Two retires it.**
    var ignores: Int = 0
    /// Set when decay switched it off, so the list can say so rather than looking like
    /// the user turned it off.
    var retired: Bool = false
    var lastFired: Date?

    /// A page you ignore twice is retired, and the watch behind it goes quiet.
    static let decayLimit = 2
}

/// Something a watch found, ready to become a page.
struct MarginNudge: Identifiable {
    let id: String
    let watchID: String
    let volume: MarginVolume
    /// The line above the page — "In 4 minutes", "Held for you".
    let kicker: String
    /// What it noticed, in one or two sentences, written for a person.
    let body: String
    /// Why it is watching this at all. Shown small; absent for built-ins that are obvious.
    var why: String?
    var primary: (label: String, action: @MainActor () async throws -> String)?
    var secondaryLabel: String = "Leave it"
    /// When this stops being worth saying — a meeting that has started, a slot gone.
    var expires: Date?
}
