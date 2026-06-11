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

    /// A user is "in an active call" only when some process has the microphone actually
    /// running. A conference app merely being open/frontmost is **not** sufficient — an
    /// idle Zoom/Teams window left open all day must not latch us into "in call" and
    /// silently mute every reminder + hold the cancellation notice indefinitely (the
    /// v2.7.0 regression: 11.5h of stuck suppression). Real calls keep the mic device
    /// "running" via `kAudioDevicePropertyDeviceIsRunningSomewhere` even when muted, so
    /// genuine calls still detect; `isConferenceAppActive` survives as a Live-Signals
    /// detail but no longer asserts in-call on its own.
    var isInActiveCall: Bool { isMicrophoneInUseElsewhere }
}

/// Aggregates the four context detectors into a single observable snapshot.
///
/// Owns the detectors; the rest of the app only ever reads `snapshot`. The escalation
/// policy is a pure function that consumes the snapshot — no state, no side effects —
/// so the rules are trivially testable in isolation.
@MainActor
final class MeetingContextMonitor: ObservableObject {

    @Published private(set) var snapshot: MeetingContextSnapshot

    let frontmost: FrontmostAppDetector
    let screen: ScreenCaptureDetector
    let microphone: MicrophoneDetector
    let focus: FocusModeDetector

    private var cancellables = Set<AnyCancellable>()

    init() {
        let frontmost = FrontmostAppDetector()
        let microphone = MicrophoneDetector()
        // Screen capture detector reads live state from frontmost + mic — inject closures
        // so it stays decoupled and re-evaluates when those inputs change.
        let screen = ScreenCaptureDetector(
            frontmostBundleIDProvider: { [weak frontmost] in frontmost?.frontmostBundleID },
            microphoneInUseProvider: { [weak microphone] in microphone?.isMicrophoneInUseElsewhere ?? false }
        )
        self.frontmost = frontmost
        self.microphone = microphone
        self.screen = screen
        self.focus = FocusModeDetector()

        self.snapshot = MeetingContextSnapshot(
            frontmostBundleID: nil,
            isConferenceAppActive: false,
            isMicrophoneInUseElsewhere: false,
            isScreenCaptured: false,
            isFocusActive: false,
            isFullscreenAppActive: false
        )

        // When the frontmost app or mic-in-use state changes, ask screen-capture to
        // re-evaluate (its computed state depends on both).
        frontmost.$frontmostBundleID
            .receive(on: DispatchQueue.main)
            .sink { [weak screen] _ in screen?.refresh() }
            .store(in: &cancellables)
        microphone.$isMicrophoneInUseElsewhere
            .receive(on: DispatchQueue.main)
            .sink { [weak screen] _ in screen?.refresh() }
            .store(in: &cancellables)

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
