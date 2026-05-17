import Combine
import Foundation
import Intents

/// Owns the on-meeting-start / on-meeting-end side effects. Listens to set-diffs on
/// `CalendarManager.meetingsCurrentlyRunning` and dispatches: audio output switch,
/// Focus enable, snapshot save → restore on the way back out.
///
/// The coordinator is intentionally state-light: the source of truth is
/// `HandoffStateSnapshot` in UserDefaults, which means an app crash mid-meeting
/// still leaves a recovery path at next launch.
@MainActor
final class MeetingHandoffCoordinator: ObservableObject {

    /// Most recent outcome of a Focus invocation. Surfaced in Settings.
    @Published private(set) var lastFocusOutcome: FocusModeController.Outcome?

    private let router: AudioRouter
    private let focus: FocusModeController
    private let config: HandoffConfigManager
    private weak var calendarManager: CalendarManager?

    private var runningMeetingIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(router: AudioRouter, focus: FocusModeController, config: HandoffConfigManager) {
        self.router = router
        self.focus = focus
        self.config = config
    }

    /// Settings UI hook: dry-run the Focus enable path so the user can see whether their
    /// Shortcuts setup actually works without scheduling a real meeting. Does NOT snapshot
    /// or take any other action.
    func testFocusEnable() async {
        lastFocusOutcome = await focus.enable()
    }

    /// Subscribe to the calendar manager and recover any stale snapshot from a crash.
    func attach(to calendarManager: CalendarManager) {
        self.calendarManager = calendarManager

        // Crash-recovery: if we have a snapshot whose meeting endTime is already past,
        // restore immediately. Avoids leaving the user stuck on AirPods + Focus on
        // after a force-quit.
        if let stale = HandoffStateSnapshot.load(), stale.endTime <= Date() {
            Task { await self.restore(from: stale) }
        }

        calendarManager.$meetingsCurrentlyRunning
            .removeDuplicates()
            .sink { [weak self] meetings in
                Task { @MainActor [weak self] in await self?.reconcile(meetings: meetings) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reconciliation

    /// Compute the set diff between the previously-running meetings and the current set.
    /// New entries trigger handoff-on; removed entries trigger restore.
    private func reconcile(meetings: [MeetingEvent]) async {
        let currentIDs = Set(meetings.map(\.id))
        let started = currentIDs.subtracting(runningMeetingIDs)
        let ended = runningMeetingIDs.subtracting(currentIDs)

        runningMeetingIDs = currentIDs

        // Only handle the first started meeting per cycle — overlapping meetings are
        // rare and would compound restore complexity. We snapshot once per meeting.
        if let firstStarted = started.first,
           let meeting = meetings.first(where: { $0.id == firstStarted }),
           HandoffStateSnapshot.load() == nil {
            await onMeetingStart(meeting)
        }

        if !ended.isEmpty, let snapshot = HandoffStateSnapshot.load(), ended.contains(snapshot.meetingID) {
            await restore(from: snapshot)
        }
    }

    // MARK: - Start

    private func onMeetingStart(_ meeting: MeetingEvent) async {
        let priorDeviceUID = router.devices.first(where: { $0.id == router.currentDeviceID })?.uid
        let priorFocus = (INFocusStatusCenter.default.focusStatus.isFocused ?? false)

        HandoffStateSnapshot(
            meetingID: meeting.id,
            endTime: meeting.endDate,
            priorOutputDeviceUID: priorDeviceUID,
            priorFocusWasActive: priorFocus
        ).save()

        if config.audioHandoffEnabled, let target = preferredDevice() ?? fallbackDevice() {
            router.setDefaultOutput(deviceID: target.id)
        }

        if config.focusHandoffEnabled {
            lastFocusOutcome = await focus.enable()
        }
    }

    // MARK: - Restore

    private func restore(from snapshot: HandoffStateSnapshot) async {
        if config.restoreOnEnd {
            if let priorUID = snapshot.priorOutputDeviceUID,
               let priorDevice = router.devices.first(where: { $0.uid == priorUID }) {
                router.setDefaultOutput(deviceID: priorDevice.id)
            }
            if config.focusHandoffEnabled && !snapshot.priorFocusWasActive {
                lastFocusOutcome = await focus.disable()
            }
        }
        HandoffStateSnapshot.clear()
    }

    // MARK: - Device picking

    private func preferredDevice() -> AudioRouter.OutputDevice? {
        guard let uid = config.preferredOutputUID, !uid.isEmpty else { return nil }
        return router.devices.first(where: { $0.uid == uid })
    }

    private func fallbackDevice() -> AudioRouter.OutputDevice? {
        if let uid = config.fallbackOutputUID, !uid.isEmpty,
           let device = router.devices.first(where: { $0.uid == uid }) {
            return device
        }
        return router.builtInOutput
    }
}
