import AppKit
import Combine
import Foundation

/// Heuristically reports whether the user is likely capturing or sharing their screen.
///
/// macOS does not expose a public "is being captured" signal — the purple menu bar icon
/// is user-facing only — so we infer from two signals that don't require any new
/// permissions:
///
/// 1. **Recorder app present**: a known screen-recording application is running.
/// 2. **Presenting**: a conference app is frontmost AND another app has the mic running
///    (typical for "I'm in Zoom and sharing right now"). The mic signal already lights
///    up because the conference app is using it; this just adds the frontmost gate.
///
/// We update on `NSWorkspace.didLaunchApplicationNotification` and
/// `didTerminateApplicationNotification` plus on every frontmost-app change.
@MainActor
final class ScreenCaptureDetector: ObservableObject {

    @Published private(set) var isScreenCaptured: Bool = false

    /// Bundle IDs of apps that are usually only running while someone is recording or
    /// streaming the screen. Adding entries is safe; false positives just mean a voice
    /// reminder gets suppressed.
    private static let recorderBundleIDs: Set<String> = [
        "com.obsproject.obs-studio",
        "com.loom.desktop",
        "com.loomhq.desktop",
        "com.syniumsoftware.Screenium3",
        "com.telestream.screenflow11",
        "com.telestream.screenflow10",
        "com.telestream.screenflow9",
        "com.TechSmith.Snagit2024",
        "com.TechSmith.Snagit2023",
        "com.apple.QuickTimePlayerX",   // matches when Screen Recording is active
        "com.kapwing.kapture",
        "com.cleanshotapp.cleanshot",
    ]

    private var launchObserver: Any?
    private var terminateObserver: Any?
    private var activateObserver: Any?

    init(frontmostBundleIDProvider: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         microphoneInUseProvider: @escaping () -> Bool = { false }) {
        self.frontmostBundleID = frontmostBundleIDProvider
        self.microphoneInUse = microphoneInUseProvider
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        activateObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Re-evaluate on demand. Other detectors call this when their state changes (for
    /// example, MicrophoneDetector publishes a change → MeetingContextMonitor pokes us).
    func refresh() {
        isScreenCaptured = computeCurrentState()
    }

    private let frontmostBundleID: () -> String?
    private let microphoneInUse: () -> Bool

    private static let conferenceBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webex.meetings",
        "com.logmein.GoToMeeting",
    ]

    private func computeCurrentState() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !running.isDisjoint(with: Self.recorderBundleIDs) { return true }

        if let fm = frontmostBundleID(),
           Self.conferenceBundleIDs.contains(fm),
           microphoneInUse() {
            return true
        }
        return false
    }
}
