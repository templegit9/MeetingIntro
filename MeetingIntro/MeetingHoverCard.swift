import SwiftUI

// MARK: - MeetingHoverCard

/// A glance-affordance card rendered inside a `.popover` off a meeting row in the
/// menu-bar dropdown. Surfaces fuller event detail (time, location, organizer, attendees,
/// RSVP breakdown, notes snippet, join-link indicator) without duplicating the Join
/// button that already lives on the row.
///
/// Sizing follows the SettingsSectionHeader info-popover precedent in SettingsView.swift
/// (line ~2209): `frame(width: 280)`, `.padding(14)`, `.fixedSize(horizontal: false,
/// vertical: true)`.  Light/standard styling (`.primary`/`.secondary`/`.tint`) — NOT
/// the white-on-dark of MeetingDetailsPanel, which targets the overlay NSPanel.
struct MeetingHoverCard: View {

    let meeting: MeetingEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.vertical, 10)
            timeSection
            if meeting.location != nil   { locationRow.padding(.top, 6) }
            if meeting.organizerName != nil { organizerRow.padding(.top, 6) }
            if meeting.attendeeCount > 0 { attendeeSection.padding(.top, 10) }
            if hasNotes                  { notesSection.padding(.top, 10) }
            if meeting.url != nil        { joinLinkBadge.padding(.top, 10) }
        }
        .padding(14)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header (title + calendar dot)

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(calendarDotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 3)          // optical alignment with first text line

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(meeting.calendarName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Time row

    private var timeSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if meeting.isAllDay {
                Text("All day")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            } else {
                Text(timeRangeString)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                + Text("  \(durationString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if meeting.isRecurring {
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .help("Recurring event")
            }
        }
    }

    // MARK: - Location row

    private var locationRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "location")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(meeting.location ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Organizer row

    private var organizerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "person")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(meeting.organizerName ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Attendee section

    private var attendeeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            cardSectionHeader("ATTENDEES")

            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(attendeeSummaryLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            // RSVP breakdown — only when the calendar reported counts
            if let counts = meeting.responseCounts, counts.total > 0 {
                Text(rsvpBreakdown(counts))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)   // indent under icon column
            }

            // The user's own RSVP, skipping organizer/unknown (no label)
            if let myLabel = meeting.myResponse.label {
                HStack(spacing: 4) {
                    Image(systemName: myResponseGlyph)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(myResponseColor)
                    Text(myLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(myResponseColor)
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Notes section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            cardSectionHeader("NOTES")

            Text(meeting.notes ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Join-link indicator

    /// Informational badge only — the row already has a Join button.
    private var joinLinkBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Has a join link")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Section header helper

    private func cardSectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .default))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    // MARK: - Computed helpers

    /// Deterministic dot color derived from the calendar name string alone.
    /// `CalendarInfo.color` (hex) isn't available on `MeetingEvent` without an async
    /// fetch, so we hash the name to one of seven distinguishable semantic palette
    /// slots.  These match the Apple Calendar color wheel order so common calendar
    /// names (Work, Personal, Home…) land on predictable hues.
    private var calendarDotColor: Color {
        let palette: [Color] = [
            Color(red: 0.25, green: 0.52, blue: 0.96),   // blue   (index 0)
            Color(red: 0.20, green: 0.78, blue: 0.35),   // green  (index 1)
            Color(red: 0.96, green: 0.34, blue: 0.33),   // red    (index 2)
            Color(red: 0.98, green: 0.62, blue: 0.11),   // orange (index 3)
            Color(red: 0.63, green: 0.37, blue: 0.94),   // purple (index 4)
            Color(red: 0.20, green: 0.67, blue: 0.86),   // teal   (index 5)
            Color(red: 0.96, green: 0.80, blue: 0.17),   // yellow (index 6)
        ]
        let hash = abs(meeting.calendarName.hashValue)
        return palette[hash % palette.count]
    }

    private var timeRangeString: String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return "\(fmt.string(from: meeting.startDate)) – \(fmt.string(from: meeting.endDate))"
    }

    /// "45m", "1h", "1h 30m", "2h", etc.
    private var durationString: String {
        let minutes = Int(meeting.endDate.timeIntervalSince(meeting.startDate) / 60)
        guard minutes > 0 else { return "" }
        let h = minutes / 60
        let m = minutes % 60
        switch (h, m) {
        case (0, let m):  return "\(m)m"
        case (let h, 0):  return "\(h)h"
        default:          return "\(h)h \(m)m"
        }
    }

    /// "5 people" or "5 people · Alice, Bob + 3 more"
    private var attendeeSummaryLine: String {
        let count = meeting.attendeeCount
        let label = count == 1 ? "1 person" : "\(count) people"
        let visible = meeting.attendeeNames.prefix(2)
        let extra = max(0, count - 2)
        if visible.isEmpty { return label }
        let names = visible.joined(separator: ", ")
        return extra > 0 ? "\(label) · \(names) + \(extra) more" : "\(label) · \(names)"
    }

    /// "5 accepted · 1 declined · 2 tentative · 1 no reply"  (omits zero-count slots)
    private func rsvpBreakdown(_ c: ResponseCounts) -> String {
        var parts: [String] = []
        if c.accepted   > 0 { parts.append("\(c.accepted) accepted") }
        if c.declined   > 0 { parts.append("\(c.declined) declined") }
        if c.tentative  > 0 { parts.append("\(c.tentative) tentative") }
        if c.noResponse > 0 { parts.append("\(c.noResponse) no reply") }
        return parts.joined(separator: " · ")
    }

    private var hasNotes: Bool {
        !(meeting.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SF Symbol matching the user's own RSVP state.
    private var myResponseGlyph: String {
        switch meeting.myResponse {
        case .accepted:   return "checkmark.circle.fill"
        case .declined:   return "xmark.circle.fill"
        case .tentative:  return "questionmark.circle.fill"
        case .noResponse: return "person.crop.circle.badge.clock"
        case .organizer:  return "star.circle.fill"
        case .unknown:    return "circle"
        }
    }

    /// Color for the "Your response" badge — accepted goes green, declined red,
    /// tentative orange, everything else secondary.
    private var myResponseColor: Color {
        switch meeting.myResponse {
        case .accepted:  return .green
        case .declined:  return .red
        case .tentative: return .orange
        default:         return Color(.secondaryLabelColor)
        }
    }
}
