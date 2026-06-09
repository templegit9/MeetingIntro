import AppKit
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

    /// Posted-on-start notifier. Optional so the coordinator stays decoupled — if not set,
    /// no notification fires (Settings UI still surfaces state).
    var notificationManager: NotificationManager?

    /// Transcription + notes pipeline; late-wired in AppLifecycleManager.observe.
    /// Every finalized recording (meeting end, manual stop, pre-sleep stop) is
    /// offered to it — the pipeline itself decides based on the auto toggle.
    var notesPipeline: MeetingNotesPipeline?

    /// Diagnostic log — injected in AppLifecycleManager.observe.
    var diagnosticLog: DiagnosticLog?

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

        // Sleep/wake — recording can't survive system sleep cleanly (SCStream and
        // AVCaptureSession pause and the AVAssetWriter is in an undefined state on wake),
        // so we finalize the file before sleep and start a new one on wake if the meeting
        // is still going.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.handleWillSleep() }
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.handleDidWake() }
            }
            .store(in: &cancellables)
    }

    /// On system sleep: finalize whatever's recording so the file is playable. We do NOT
    /// clear `runningMeetingIDs` here because that's the wake handler's job — we want
    /// `handleDidWake` to see the meetings as "fresh starts" so it can re-arm recording
    /// in a new file.
    private func handleWillSleep() async {
        guard controller.isRecording else { return }
        // A partial transcript beats none — pre-sleep stops feed the pipeline too.
        await stopAndEnqueueNotes()
        // Intentionally leave the RecordingSession snapshot in place so a crash during
        // sleep is still recoverable on next launch. The wake handler will clear it.
    }

    /// On wake: if a meeting is still scheduled to be running (per the calendar's view)
    /// and recording is configured, restart recording in a new file. We can't resume
    /// the pre-sleep file — AVAssetWriter has no resume API. The pre-sleep file is
    /// already finalized and saved.
    private func handleDidWake() async {
        runningMeetingIDs = []
        RecordingSession.clear()
        if let calendarManager {
            await reconcile(meetings: calendarManager.meetingsCurrentlyRunning)
        }
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

        // If our active recording's meeting ended, stop, clear the snapshot, and
        // hand the finalized file to the notes pipeline.
        if let activeSession = RecordingSession.load(),
           ended.contains(activeSession.meetingID) {
            await stopAndEnqueueNotes()
            RecordingSession.clear()
        }
    }

    private func shouldRecord(_ meeting: MeetingEvent) -> Bool {
        config.isEnabled
            && config.hasAcceptedDisclaimer
            && meeting.url != nil
            && !meeting.isCancelled
    }

    private func beginRecording(_ meeting: MeetingEvent) async {
        let directory = config.resolveSaveDirectory()
        do {
            let fileURL = try await controller.start(for: meeting, saveDirectory: directory)
            diagnosticLog?.info(.recording, "Recording started — \(meeting.title)")
            RecordingSession(
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                fileURL: fileURL,
                startedAt: Date(),
                meetingEndTime: meeting.endDate
            ).save()
            lastError = nil
            notificationManager?.sendRecordingStartedNotification(for: meeting)
        } catch {
            lastError = error.localizedDescription
            diagnosticLog?.error(.recording, "Recording failed to start: \(error.localizedDescription)")
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

    /// Manual stop button in Settings / menu bar.
    func stopManually() async {
        await stopAndEnqueueNotes()
        RecordingSession.clear()
    }

    /// Passthrough for the AppDelegate so it can block app termination only when a
    /// recording is actually in progress, without holding a direct reference to the
    /// controller.
    var isRecording: Bool { controller.isRecording }

    /// Stop the active recording and offer the finalized file to the notes
    /// pipeline. Centralizes the capture-URL-before-stop dance (stop() nils
    /// `currentFileURL` during teardown).
    func stopAndEnqueueNotes() async {
        let fileURL = controller.currentFileURL
        await controller.stop()
        if let fileURL {
            diagnosticLog?.info(.recording, "Recording stopped, enqueuing for notes — \(fileURL.lastPathComponent)")
            notesPipeline?.enqueueIfAutoEnabled(audioURL: fileURL)
        }
    }
}
