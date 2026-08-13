import Foundation

/// How the countdown overlay presents **several meetings that start at the same time**.
///
/// Before this existed the app showed exactly one of them and silently swallowed the
/// rest: `evaluateCountdownTrigger` fired the first meeting and returned, and on the
/// next poll the others were marked as already-triggered *before* the
/// "is an overlay already up?" check rejected them — so they were never shown and never
/// retried. All four styles below replace that path; which one you get is a setting,
/// because the right answer depends on how often you're double-booked and how loud you
/// want the reminder to be.
///
/// A "clash" is the set of meetings whose reminder threshold crosses in the **same
/// 30s poll** — so 10:00 + 10:00 group together, while 9:58 + 10:00 don't.
enum ConcurrentOverlayStyle: String, CaseIterable, Identifiable {
    /// One overlay owns the timeslot: a shared countdown ring, then a row per meeting
    /// with its own Join. The conflict itself is the headline.
    case conflictPanel
    /// Today's full overlay for the top-ranked meeting, plus a compact
    /// "also at this time" strip for the others.
    case heroPlusStrip
    /// One meeting at a time with a ‹ 1 of 3 › pager; Dismiss advances instead of closing.
    case pager
    /// A stack of compact cards, one per meeting, each dismissable on its own.
    case cardStack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conflictPanel: return "Conflict panel"
        case .heroPlusStrip: return "Hero + also-at-this-time"
        case .pager:         return "One at a time (pager)"
        case .cardStack:     return "Card stack"
        }
    }

    var summary: String {
        switch self {
        case .conflictPanel:
            return "One overlay for the whole timeslot: a shared countdown and a row per meeting, each with its own Join. Best when you want the clash itself to be the headline."
        case .heroPlusStrip:
            return "The usual overlay for the most likely meeting — ring, details, Join — with the others listed underneath. Closest to the single-meeting experience."
        case .pager:
            return "Full detail for each meeting, one at a time. Dismiss moves to the next instead of closing. You act on every meeting."
        case .cardStack:
            return "A compact card per meeting, stacked in the corner. Every meeting is equal and independently dismissable; scales best past three."
        }
    }

    var symbol: String {
        switch self {
        case .conflictPanel: return "rectangle.3.group"
        case .heroPlusStrip: return "rectangle.topthird.inset.filled"
        case .pager:         return "rectangle.on.rectangle.angled"
        case .cardStack:     return "square.stack.3d.up"
        }
    }
}
