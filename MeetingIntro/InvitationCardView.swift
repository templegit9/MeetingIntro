import AppKit
import SwiftUI

/// One invitation, in either dropdown presentation.
///
/// **Shared on purpose.** The two dropdowns are otherwise deliberately separate view
/// trees, but the rules on this card — a decline that confirms and names the organizer,
/// a failure that says the organizer wasn't notified, an action that is absent rather
/// than disabled — are the design, not the chrome. Two copies would drift, and drift
/// here means one presentation quietly lying about whether a reply was sent.
///
/// Only spacing, type size and background differ between the styles; every branch below
/// is common to both.
struct InvitationCardView: View {
    @ObservedObject var invitations: InvitationCenter
    @ObservedObject var calendarManager: CalendarManager
    let meeting: MeetingEvent
    let accent: Color
    /// Menu-styled list (`CompactMenuView`) rather than the rich popover's card.
    var compact: Bool = false
    /// Lets the parent dim the other cards while this one is proposing.
    @Binding var proposingID: String?

    @State private var confirmingDecline = false
    @State private var proposedStart = Date()
    @State private var proposedDuration: TimeInterval = 3600
    @State private var pickingTime = false

    private var isProposing: Bool { proposingID == meeting.id }
    private var state: InvitationState? { invitations.state(for: meeting.id) }
    private var failed: Bool { if case .failed = state { return true }; return false }

    // Layout metrics — the only thing the two styles actually disagree about.
    private var titleSize: CGFloat { compact ? 12 : 13 }
    private var bodySize: CGFloat { compact ? 10.5 : 11 }
    private var pad: CGFloat { compact ? 8 : 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            Text(meeting.title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)

            secondLine

            if isProposing, state == nil {
                proposeBox
            } else {
                actions
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(failed ? Color.red.opacity(0.13) : Color.primary.opacity(compact ? 0.04 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(failed ? Color.red.opacity(0.45) : Color.primary.opacity(0.10), lineWidth: 1))
    }

    /// Whatever the card most needs to say right now.
    @ViewBuilder private var secondLine: some View {
        if case .failed(_, let message) = state {
            Text(message).font(.system(size: bodySize)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .sending(let sending) = state {
            Text("Sending \(sending.sentVerb)…").font(.system(size: bodySize)).foregroundStyle(.secondary)
        } else if confirmingDecline {
            // Names the person, because that's the consequence. "Are you sure?" tests nothing.
            Text("Decline this? \(organizerLabel) is notified right away.")
                .font(.system(size: bodySize)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(whenLine).font(.system(size: bodySize)).foregroundStyle(.secondary).lineLimit(1)
            if !calendarManager.canRespond(to: meeting) {
                Text("This account can't send replies")
                    .font(.system(size: bodySize)).foregroundStyle(.secondary)
            } else if let clash = firstConflict {
                Text("Conflicts with \(clash)")
                    .font(.system(size: bodySize)).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if case .sending = state {
            HStack { Spacer(minLength: 0); ProgressView().controlSize(.small) }
        } else if case .failed = state {
            HStack(spacing: 6) {
                button("Retry", tint: .red, filled: true) { Task { await invitations.retry(meeting) } }
                button("Open in Calendar") { openInCalendar() }
                Spacer(minLength: 0)
            }
        } else if !calendarManager.canRespond(to: meeting) {
            // Absence, never disablement: one action that works beats three that can't.
            HStack { button("Open in Calendar") { openInCalendar() }; Spacer(minLength: 0) }
        } else if confirmingDecline {
            HStack(spacing: 6) {
                button("Send decline", tint: .red, filled: true) {
                    confirmingDecline = false
                    Task { await invitations.respond(to: meeting, status: .declined) }
                }
                button("Keep") { confirmingDecline = false }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                // Accept and Tentative send straight through. Only the answer that
                // disappoints someone earns a second beat.
                button("Accept", tint: .green, filled: true) {
                    Task { await invitations.respond(to: meeting, status: .accepted) }
                }
                button("Tentative") { Task { await invitations.respond(to: meeting, status: .tentative) } }
                button("Decline") { confirmingDecline = true }
                Spacer(minLength: 0)
                // Absent unless the organizer allowed it — never a disabled link
                // explaining something the user can't have.
                if meeting.allowsNewTimeProposals {
                    Button("Propose…") { beginProposing() }
                        .buttonStyle(.plain).font(.system(size: bodySize)).foregroundStyle(accent)
                }
            }
        }
    }

    /// One slot, not a list — and the caveat sits in the card, visible at the moment of
    /// sending, because we know your calendar and nothing about theirs.
    @ViewBuilder private var proposeBox: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposedStart.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: titleSize - 1, weight: .semibold))
                        Text("Your next free hour — we haven't checked theirs")
                            .font(.system(size: bodySize - 0.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    button("Send", tint: .green, filled: true) {
                        let start = proposedStart
                        let end = start.addingTimeInterval(proposedDuration)
                        proposingID = nil
                        pickingTime = false
                        Task { await invitations.propose(to: meeting, start: start, end: end) }
                    }
                }
                if pickingTime {
                    DatePicker("", selection: $proposedStart, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact).labelsHidden().controlSize(.small)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            HStack {
                Button(pickingTime ? "Use the suggestion" : "Pick another time…") {
                    if pickingTime {
                        pickingTime = false
                        if let slot = invitations.suggestedSlot(for: meeting) { proposedStart = slot.start }
                    } else {
                        pickingTime = true
                    }
                }
                .buttonStyle(.plain).font(.system(size: bodySize)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Button("Cancel") { proposingID = nil; pickingTime = false }
                    .buttonStyle(.plain).font(.system(size: bodySize)).foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ title: String, tint: Color = .secondary, filled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: bodySize, weight: .medium))
                .padding(.horizontal, compact ? 8 : 9)
                .padding(.vertical, compact ? 3 : 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(filled ? tint.opacity(0.85) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(filled ? Color.clear : Color.primary.opacity(0.22), lineWidth: 1))
                .foregroundStyle(filled ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func beginProposing() {
        proposedDuration = max(meeting.endDate.timeIntervalSince(meeting.startDate), 900)
        if let slot = invitations.suggestedSlot(for: meeting) {
            proposedStart = slot.start
            pickingTime = false
        } else {
            // Nothing free in the next fortnight: ask for a time rather than invent one.
            proposedStart = meeting.startDate
            pickingTime = true
        }
        proposingID = meeting.id
    }

    /// When it is, how far out when that itself changes the answer, and who asked.
    private var whenLine: String {
        let cal = Calendar.current
        var parts: [String] = []
        if cal.isDateInToday(meeting.startDate) {
            parts.append("Today \(meeting.formattedStartTime)")
        } else if cal.isDateInTomorrow(meeting.startDate) {
            parts.append("Tomorrow \(meeting.formattedStartTime)")
        } else {
            parts.append("\(meeting.startDate.formatted(.dateTime.month(.abbreviated).day())), \(meeting.formattedStartTime)")
        }
        let days = cal.dateComponents([.day], from: Date(), to: meeting.startDate).day ?? 0
        if days >= 7 { parts.append(meeting.startDate.formatted(.relative(presentation: .named))) }
        if let org = meeting.organizerName, !org.isEmpty { parts.append(org) }
        return parts.joined(separator: " · ")
    }

    private var organizerLabel: String {
        if let org = meeting.organizerName, !org.isEmpty { return org }
        return "The organizer"
    }

    /// Only ever a real clash: the meeting itself is excluded. Bounded by the reminder
    /// window, so a far-out invitation shows no line rather than a wrong one.
    private var firstConflict: String? {
        calendarManager.conflicts(start: meeting.startDate, end: meeting.endDate)
            .first { $0.id != meeting.id }?.title
    }

    private func openInCalendar() { NSWorkspace.shared.open(URL(string: "ical://")!) }
}

/// The dashed row an answered invitation leaves behind for the session.
struct AnsweredInvitationRow: View {
    @ObservedObject var invitations: InvitationCenter
    let answered: AnsweredInvitation
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(answered.event.title) · \(answered.status.pastLabel)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if invitations.canUndo(answered.id) {
                Button("Undo") { Task { await invitations.undo(answered.event) } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            } else {
                // Nothing can return an invitation to "no response", so the honest
                // affordance reopens the actions rather than promising an undo.
                Button("Change…") { invitations.reopen(answered.event) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }
}
