import Combine
import Foundation

/// Drives the menu-bar countdown for meetings armed via "Start at Time".
///
/// When at least one meeting is armed, a 1-second timer ticks: it (1) asks
/// `CalendarManager.evaluateAutoJoin()` to open any meeting that has reached its
/// start time — so the link opens within ~1s of the displayed `0:00` rather than
/// up to 30s later on the next poll — and (2) republishes `text`, the short
/// countdown string the `MenuBarExtra` label renders beside the icon.
///
/// The timer is **gated on the armed set** (subscribes to `armedAutoJoinIDs`): it
/// runs only while something is armed and stops the moment the set empties, so an
/// idle app isn't waking every second.
@MainActor
final class MenuBarCountdownModel: ObservableObject {

    /// Short countdown for the menu bar (e.g. "9:58", "0:42", "1h5m"). `nil` when
    /// nothing is armed — the label falls back to the normal icon.
    @Published private(set) var text: String?

    private weak var calendarManager: CalendarManager?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func configure(calendarManager: CalendarManager) {
        self.calendarManager = calendarManager
        // Start/stop the ticker as the armed set gains/loses members.
        calendarManager.$armedAutoJoinIDs
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] active in
                if active { self?.startTicking() } else { self?.stopTicking() }
            }
            .store(in: &cancellables)
    }

    private func startTicking() {
        guard timer == nil else { return }
        tick() // immediate, so the menu bar updates without waiting a second
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // .common so the countdown keeps updating while a menu/tracking loop is open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
        text = nil
    }

    private func tick() {
        guard let cm = calendarManager else { stopTicking(); return }
        // Fire any due auto-join first (this may open + disarm meetings), then read
        // the remaining armed set for display.
        cm.evaluateAutoJoin()
        guard let next = cm.armedAutoJoinMeetings.first else {
            // Set is empty now; the $armedAutoJoinIDs subscription will stop us, but
            // clear the text immediately so the label reverts this frame.
            text = nil
            return
        }
        text = Self.format(next.startDate.timeIntervalSinceNow)
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
