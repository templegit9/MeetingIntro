import AppKit
import SwiftUI

/// A compact info panel that appears inside the countdown overlay when the meeting is
/// still ≥15 minutes (configurable) out. Surfaces notes, attendees, and a secondary
/// join-link row — content the user would otherwise alt-tab to dig up.
struct MeetingDetailsPanel: View {

    let meeting: MeetingEvent
    /// Tighter layout, mirroring `CountdownOverlayView.compact` — the panel has to fit
    /// in a shorter overlay on smaller screens.
    var compact: Bool = false

    @AppStorage("contextPanelShowNotes") private var showNotes: Bool = true
    @AppStorage("contextPanelShowAttendees") private var showAttendees: Bool = true
    @AppStorage("contextPanelShowJoinURL") private var showJoinURL: Bool = true

    @State private var notesExpanded: Bool = false
    @State private var didCopy: Bool = false

    private var hasNotes: Bool {
        showNotes && !(meeting.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasAttendees: Bool { showAttendees && !meeting.attendeeNames.isEmpty }
    private var hasJoinURL: Bool { showJoinURL && meeting.url != nil }

    /// Whether any subsection is actually going to render. Callers should check this to
    /// avoid showing an empty container.
    var hasContent: Bool { hasNotes || hasAttendees || hasJoinURL }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if hasNotes { notesSection }
            if hasAttendees { attendeesSection }
            if hasJoinURL { joinURLSection }
        }
        .padding(.horizontal, compact ? 22 : 32)
    }

    // MARK: - Sections

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Notes")
            ScrollView {
                Text(meeting.notes ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(notesExpanded ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            .frame(maxHeight: notesExpanded ? (compact ? 130 : 180) : (compact ? 72 : 110))

            if (meeting.notes ?? "").count > 280 {
                Button(notesExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) { notesExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Attendees (\(meeting.attendeeCount))")
            Text(attendeeDisplay)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Everyone's RSVP breakdown, when the calendar reported it.
            if let c = meeting.responseCounts, c.total > 0 {
                Text(rsvpSummary(c))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            // The user's own response, when it's a real invitation.
            if let mine = meeting.myResponse.label {
                Text("Your response: \(mine)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func rsvpSummary(_ c: ResponseCounts) -> String {
        var parts: [String] = []
        if c.accepted > 0 { parts.append("\(c.accepted) accepted") }
        if c.declined > 0 { parts.append("\(c.declined) declined") }
        if c.tentative > 0 { parts.append("\(c.tentative) tentative") }
        if c.noResponse > 0 { parts.append("\(c.noResponse) no reply") }
        return parts.joined(separator: " · ")
    }

    private var joinURLSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Join Link")
            HStack(spacing: 8) {
                Text(meeting.url?.absoluteString ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button { copyURL() } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Copy join link")

                Button {
                    if let url = meeting.url { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            }
        }
    }

    // MARK: - Helpers

    private var attendeeDisplay: String {
        let visible = meeting.attendeeNames.prefix(6).joined(separator: ", ")
        let extra = max(0, meeting.attendeeCount - 6)
        return extra > 0 ? "\(visible) + \(extra) more" : visible
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.55))
    }

    private func copyURL() {
        guard let url = meeting.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
