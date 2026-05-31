import Combine
import Foundation

/// Drives the auto-recording flow off `CalendarManager.meetingsCurrentlyRunning`.
///
/// Same set-diff pattern as `MeetingHandoffCoordinator`: on enter, decide whether to
/// record (gated on toggle + disclaimer + the meeting having a conference URL); on
/// exit, finalize. Crash recovery on attach.
@MainActor
final class MeetingRecordingCoordinator: ObservableObject {

    /// Surfaced for the Settings UI banner when permission/setup fails. Nil between runs.
    @Published private(set) var lastError: String?

    private let config: RecordingConfig
    private let controller: RecordingController
    private weak var calendarManager: CalendarManager?

    private var runningMeetingIDs: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    init(config: RecordingConfig, controller: RecordingController) {
        self.config = config
        self.controller = controller
    }

    /// Subscribe to the calendar manager and recover any stale recording snapshot.
    func attach(to calendarManager: CalendarManager) {
        self.calendarManager = calendarManager

        Task { await self.recoverStaleSession() }

        calendarManager.$meetingsCurrentlyRunning
            .removeDuplicates()
            .sink { [weak self] meetings in
                Task { @MainActor [weak self] in await self?.reconcile(meetings: meetings) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Reconciliation

    private func reconcile(meetings: [MeetingEvent]) async {
        let currentIDs = Set(meetings.map(\.id))
        let started = currentIDs.subtracting(runningMeetingIDs)
        let ended = runningMeetingIDs.subtracting(currentIDs)

        runningMeetingIDs = currentIDs

        // First started meeting per cycle, gated on the user's preferences.
        if !controller.isRecording,
           let firstStartedID = started.first,
           let meeting = meetings.first(where: { $0.id == firstStartedID }),
           shouldRecord(meeting) {
            await beginRecording(meeting)
        }

        // If our active recording's meeting ended, stop and clear the snapshot.
        if let activeSession = RecordingSession.load(),
           ended.contains(activeSession.meetingID) {
            await controller.stop()
            RecordingSession.clear()
        }
    }

    private func shouldRecord(_ meeting: MeetingEvent) -> Bool {
        config.isEnabled
            && config.hasAcceptedDisclaimer
            && meeting.url != nil
    }

    private func beginRecording(_ meeting: MeetingEvent) async {
        let directory = config.resolveSaveDirectory()
        do {
            let fileURL = try await controller.start(for: meeting, saveDirectory: directory)
            RecordingSession(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                fileURL: fileURL,
                startedAt: Date(),
                meetingEndTime: meeting.endDate
            ).save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Crash recovery

    /// On launch, if a snapshot exists with `meetingEndTime <= now`, the previous run
    /// crashed mid-recording. Try to make the file usable; failing that, delete it.
    /// Either way clear the snapshot so we start clean.
    private func recoverStaleSession() async {
        guard let stale = RecordingSession.load() else { return }
        guard stale.meetingEndTime <= Date() else {
            // Meeting is still going; we'll let the normal flow re-establish on the next
            // poll cycle if recording is still desired. Nothing to do here.
            return
        }

        // The original AVAssetWriter is gone; we can't finishWriting() from a different
        // process. Best we can do is leave the file as-is (some players can still play
        // an unfinished AAC stream) or delete it. Default policy: delete partial files
        // so we don't litter the recordings folder with corrupted ones.
        if FileManager.default.fileExists(atPath: stale.fileURL.path) {
            // Sniff: if the file is < 100 KB it's almost certainly an empty container.
            // If it's larger, leave it for the user to inspect — they may want to
            // attempt recovery in QuickTime / ffmpeg manually.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: stale.fileURL.path),
               let size = attrs[.size] as? Int, size < 100_000 {
                try? FileManager.default.removeItem(at: stale.fileURL)
            }
        }
        RecordingSession.clear()
    }

    // MARK: - Settings UI hooks

    /// Manual stop button in Settings.
    func stopManually() async {
        await controller.stop()
        RecordingSession.clear()
    }
}
