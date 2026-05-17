import Combine
import Foundation

/// A point-in-time snapshot of the four context signals the escalation policy reads.
struct MeetingContextSnapshot: Equatable {
    let frontmostBundleID: String?
    let isConferenceAppActive: Bool
    let isMicrophoneInUseElsewhere: Bool
    let isScreenCaptured: Bool
    let isFocusActive: Bool
    let isFullscreenAppActive: Bool

    /// A user is "in an active call" when either a known video-conference app is frontmost
    /// or some other process has the microphone running. Either signal alone catches roughly
    /// half of real-world calls (Zoom native vs. Chrome-based Meet, for example); together
    /// they catch nearly all.
    var isInActiveCall: Bool { isConferenceAppActive || isMicrophoneInUseElsewhere }
}

/// Aggregates the four context detectors into a single observable snapshot.
///
/// Owns the detectors; the rest of the app only ever reads `snapshot`. The escalation
/// policy is a pure function that consumes the snapshot — no state, no side effects —
/// so the rules are trivially testable in isolation.
@MainActor
final class MeetingContextMonitor: ObservableObject {

    @Published private(set) var snapshot: MeetingContextSnapshot

    let frontmost = FrontmostAppDetector()
    let screen = ScreenCaptureDetector()
    let microphone = MicrophoneDetector()
    let focus = FocusModeDetector()

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.snapshot = MeetingContextSnapshot(
            frontmostBundleID: nil,
            isConferenceAppActive: false,
            isMicrophoneInUseElsewhere: false,
            isScreenCaptured: false,
            isFocusActive: false,
            isFullscreenAppActive: false
        )

        // Coalesce changes from all four detectors into a fresh snapshot. We don't try
        // to be clever about which detector changed — recomputing the whole snapshot is
        // cheap and avoids hard-to-reason-about partial-update bugs.
        Publishers.CombineLatest4(
            Publishers.CombineLatest(frontmost.$frontmostBundleID, frontmost.$isConferenceAppActive),
            frontmost.$isFullscreenAppActive,
            Publishers.CombineLatest(microphone.$isMicrophoneInUseElsewhere, screen.$isScreenCaptured),
            focus.$isFocusActive
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] frontmostPair, fullscreen, micScreen, focusActive in
            guard let self else { return }
            self.snapshot = MeetingContextSnapshot(
                frontmostBundleID: frontmostPair.0,
                isConferenceAppActive: frontmostPair.1,
                isMicrophoneInUseElsewhere: micScreen.0,
                isScreenCaptured: micScreen.1,
                isFocusActive: focusActive,
                isFullscreenAppActive: fullscreen
            )
        }
        .store(in: &cancellables)
    }

    /// Convenience: request Focus authorization. Settings view calls this from a button.
    func requestFocusAuthorization() async {
        await focus.requestAuthorization()
    }
}
