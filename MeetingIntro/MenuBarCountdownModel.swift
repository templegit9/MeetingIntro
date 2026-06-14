import AppKit
import Combine
import Foundation

/// Owns the dedicated menu-bar countdown for meetings armed via "Start at Time".
///
/// When at least one meeting is armed it creates its OWN `NSStatusItem` (separate from
/// the SwiftUI `MenuBarExtra`), showing a live `m:ss` countdown beside the app icon.
/// **Clicking it cancels** (disarms) the soonest armed meeting directly — the dedicated
/// status item is what makes true click-to-cancel possible (MenuBarExtra opens a menu
/// on click instead). Hovering shows a tooltip naming the meeting + "click to cancel".
///
/// A 1-second timer (gated on the armed set, so an idle app never wakes) drives both the
/// title and `CalendarManager.evaluateAutoJoin()` — so the link opens within ~1s of the
/// displayed `0:00` rather than up to 30s later on the poll. It also publishes
/// `imminentMeeting` (the soonest armed meeting once it enters the lead-time window) so
/// the gentle heads-up overlay can show/hide.
@MainActor
final class MenuBarCountdownModel: ObservableObject {

    /// The soonest armed meeting once it's within the heads-up lead window (else nil).
    /// Drives the gentle pre-start overlay; the subscriber dedups on id.
    @Published private(set) var imminentMeeting: MeetingEvent?

    private weak var calendarManager: CalendarManager?
    private weak var countdownConfig: CountdownConfigManager?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var imminentID: String?

    func configure(calendarManager: CalendarManager, countdownConfig: CountdownConfigManager) {
        self.calendarManager = calendarManager
        self.countdownConfig = countdownConfig
        // Start/stop the ticker (and the status item) as the armed set gains/loses members.
        calendarManager.$armedAutoJoinIDs
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] active in
                if active { self?.startTicking() } else { self?.stopTicking() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Ticker lifecycle

    private func startTicking() {
        guard timer == nil else { return }
        installStatusItem()
        tick() // immediate, so the menu bar updates without waiting a second
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common) // keep ticking while menus/tracking are open
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        removeStatusItem()
        if imminentMeeting != nil { imminentMeeting = nil }
        imminentID = nil
    }

    private func tick() {
        guard let cm = calendarManager else { stopTicking(); return }
        // Open any due auto-join first (may disarm + remove meetings), then read the
        // remaining armed set for display.
        cm.evaluateAutoJoin()
        guard let next = cm.armedAutoJoinMeetings.first else {
            // Empty now; the $armedAutoJoinIDs subscription will stop us, but clear
            // immediately so nothing lingers this frame.
            updateImminent(nil)
            return
        }
        let remaining = next.startDate.timeIntervalSinceNow
        updateStatusItem(for: next, remaining: remaining)

        // Heads-up window for the gentle overlay.
        let lead = TimeInterval(max(15, min(300, countdownConfig?.autoJoinOverlayLeadSeconds ?? 60)))
        let enabled = countdownConfig?.autoJoinImminentOverlayEnabled ?? true
        let inWindow = enabled && remaining > 0 && remaining <= lead
        updateImminent(inWindow ? next : nil)
    }

    private func updateImminent(_ meeting: MeetingEvent?) {
        guard meeting?.id != imminentID else { return }
        imminentID = meeting?.id
        imminentMeeting = meeting
    }

    // MARK: - Status item

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: "Auto-join armed")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        statusItem = item
    }

    private func updateStatusItem(for meeting: MeetingEvent, remaining: TimeInterval) {
        guard let button = statusItem?.button else { return }
        button.title = " " + Self.format(remaining)
        let timeStr = meeting.formattedStartTime
        button.toolTip = "Auto-join armed: \(meeting.title) at \(timeStr) — click to cancel"
    }

    private func removeStatusItem() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    /// Single click on the countdown cancels (disarms) the soonest armed meeting.
    @objc private func statusItemClicked() {
        guard let cm = calendarManager, let next = cm.armedAutoJoinMeetings.first else { return }
        cm.disarmAutoJoin(next.id)
    }

    /// Short, glanceable countdown. Seconds resolution under an hour; coarse above.
    static func format(_ remaining: TimeInterval) -> String {
        let secs = max(0, Int(remaining.rounded()))
        if secs >= 3600 {
            let h = secs / 3600, m = (secs % 3600) / 60
            return "\(h)h\(m)m"
        }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
