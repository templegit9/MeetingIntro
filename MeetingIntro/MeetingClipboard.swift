import AppKit
import Foundation

/// Copying a meeting to the clipboard, in one place.
///
/// Issues #31 and #25. Copy-to-clipboard already existed before this, but only as a
/// private `copyURL()` inside `MeetingDetailsPanel` — a surface that appears when a
/// reminder fires, which is never the moment you want to hand someone a link. Every
/// copy affordance now goes through here so the three call sites (both dropdowns and
/// the overlay's details panel) can't drift apart in what they produce.
///
/// **Three actions, deliberately, rather than one "Copy".** The reported request was
/// for "Copy Body or a generic Copy", but those are different jobs:
///
/// - `link` is what you paste into a chat to let someone in.
/// - `details` is what you paste when someone asks "what's that meeting?" — a formatted
///   block a human reads.
/// - `notes` is the organiser's own text, which is where agendas and dial-in numbers
///   live. Formatted output would bury it.
///
/// Guessing one of the three would have been wrong two times out of three.
enum MeetingClipboard {

    enum Payload {
        case link
        case details
        case notes
    }

    /// Writes `payload` for `meeting` and reports whether anything was written.
    /// Returns false when the meeting has nothing of that kind — callers should hide
    /// the affordance rather than offering a copy that silently does nothing.
    @discardableResult
    static func copy(_ payload: Payload, of meeting: MeetingEvent) -> Bool {
        guard let text = string(payload, of: meeting) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// The text a payload would produce, or nil when the meeting has none of it.
    /// Separated from `copy` so views can ask "is there anything to copy?" without
    /// touching the pasteboard.
    static func string(_ payload: Payload, of meeting: MeetingEvent) -> String? {
        switch payload {
        case .link:
            return meeting.url?.absoluteString
        case .notes:
            let trimmed = meeting.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        case .details:
            return details(of: meeting)
        }
    }

    static func has(_ payload: Payload, _ meeting: MeetingEvent) -> Bool {
        string(payload, of: meeting) != nil
    }

    // MARK: - Formatting

    /// A block a person reads, not a serialisation. Lines are omitted entirely when the
    /// field is absent — an empty "Location:" label is worse than no line.
    private static func details(of meeting: MeetingEvent) -> String {
        var lines: [String] = [meeting.title]

        lines.append(meeting.isAllDay ? allDayLine(meeting) : timeLine(meeting))

        if let location = meeting.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            lines.append("Location: \(location)")
        }
        if let organizer = meeting.organizerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !organizer.isEmpty {
            lines.append("Organiser: \(organizer)")
        }
        if !meeting.attendeeNames.isEmpty {
            lines.append("Attendees: \(attendeeSummary(meeting))")
        }
        if meeting.isCancelled {
            lines.append("CANCELLED")
        }
        if let url = meeting.url {
            lines.append(url.absoluteString)
        }
        if let notes = string(.notes, of: meeting) {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    /// Caps the list so pasting a 60-person all-hands doesn't produce a wall of names,
    /// while still reporting the true total.
    private static func attendeeSummary(_ meeting: MeetingEvent) -> String {
        let cap = 12
        let names = meeting.attendeeNames
        guard names.count > cap else { return names.joined(separator: ", ") }
        let shown = names.prefix(cap).joined(separator: ", ")
        return "\(shown) + \(names.count - cap) more"
    }

    private static func timeLine(_ meeting: MeetingEvent) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy"
        let clock = DateFormatter()
        clock.timeStyle = .short
        clock.dateStyle = .none

        let start = clock.string(from: meeting.startDate)
        let end = clock.string(from: meeting.endDate)

        // A meeting that runs past midnight needs the end date too, or "22:00 – 01:00"
        // reads as a three-hour meeting that already ended.
        if Calendar.current.isDate(meeting.startDate, inSameDayAs: meeting.endDate) {
            return "\(day.string(from: meeting.startDate)), \(start) – \(end)"
        }
        return "\(day.string(from: meeting.startDate)) \(start) – \(day.string(from: meeting.endDate)) \(end)"
    }

    private static func allDayLine(_ meeting: MeetingEvent) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy"
        return "\(day.string(from: meeting.startDate)) (all day)"
    }
}
