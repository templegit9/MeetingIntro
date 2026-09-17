import Foundation

/// A cancellation or a reschedule, recorded so it can be reviewed after the fact.
///
/// Issues #28 and #29. Before this, the two were handled very differently:
///
/// - **Cancellations** already had persistence (`notifiedCancellationIDs` /
///   `dismissedCancellationIDs`), a dropdown badge and an optional always-on-top panel
///   that survives relaunch until acknowledged.
/// - **Reschedules** had none of it. `onMeetingTimeChanged` fired one notification and
///   left no trace anywhere. Miss the banner — because you were away from the desk,
///   which is exactly when meetings get moved — and the reschedule was simply gone.
///
/// This is the shared record. It deliberately does **not** replace the cancellation
/// state above: that machinery is load-bearing for reminder suppression and has been
/// through several rounds of field debugging, so it stays as it is and this sits
/// alongside it as the reviewable log. The one thing it adds for cancellations is
/// history — the existing sets only answer "is this still pending?", never "what
/// changed today?".
struct ScheduleChange: Codable, Identifiable, Equatable {

    enum Kind: String, Codable {
        case cancelled
        case rescheduled
    }

    /// Unique per (meeting, kind, resulting start) so a meeting moved twice records two
    /// entries, while the same move seen on ten consecutive polls records one.
    let id: String
    let meetingID: String
    let title: String
    let kind: Kind
    /// Where the meeting used to start. Reschedules only; nil for cancellations.
    let previousStart: Date?
    /// The meeting's start time as of this change.
    let newStart: Date
    let detectedAt: Date
    /// Whether the user has seen and dismissed this. Acknowledged entries stay in the
    /// log for review (#29) but stop appearing as pending alerts (#28).
    var acknowledged: Bool

    static func cancelled(_ meeting: MeetingEvent, at now: Date = Date()) -> ScheduleChange {
        ScheduleChange(
            id: "\(meeting.id)\u{1F}cancelled\u{1F}\(Int(meeting.startDate.timeIntervalSince1970))",
            meetingID: meeting.id,
            title: meeting.title,
            kind: .cancelled,
            previousStart: nil,
            newStart: meeting.startDate,
            detectedAt: now,
            acknowledged: false
        )
    }

    static func rescheduled(_ meeting: MeetingEvent, from previousStart: Date, at now: Date = Date()) -> ScheduleChange {
        ScheduleChange(
            id: "\(meeting.id)\u{1F}moved\u{1F}\(Int(meeting.startDate.timeIntervalSince1970))",
            meetingID: meeting.id,
            title: meeting.title,
            kind: .rescheduled,
            previousStart: previousStart,
            newStart: meeting.startDate,
            detectedAt: now,
            acknowledged: false
        )
    }

    /// One line a person reads, e.g. "10:00 → 14:30" or "was 09:00 today".
    var summary: String {
        switch kind {
        case .cancelled:
            return "Cancelled — was \(Self.clock.string(from: newStart))"
        case .rescheduled:
            guard let previousStart else {
                return "Moved to \(Self.clock.string(from: newStart))"
            }
            // Name the day when it moved across days, or "10:00 → 10:30" would hide
            // that a meeting jumped to tomorrow.
            if Calendar.current.isDate(previousStart, inSameDayAs: newStart) {
                return "\(Self.clock.string(from: previousStart)) → \(Self.clock.string(from: newStart))"
            }
            return "\(Self.dayClock.string(from: previousStart)) → \(Self.dayClock.string(from: newStart))"
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()

    private static let dayClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
    }()
}
