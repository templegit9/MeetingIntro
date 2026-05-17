import Combine
import Foundation

/// What the policy decided for a single reminder firing. The fields shadow the per-trigger
/// flags on `CountdownTrigger`; the policy may downgrade (e.g. turn off `playVoice` even
/// when the trigger requested it) but never upgrade beyond what the trigger asked for.
struct ReminderDecision: Equatable {
    var showOverlay: Bool
    var sendNotification: Bool
    var playVoice: Bool
    var escalateOverlay: Bool

    static func fromTrigger(_ trigger: CountdownTrigger) -> ReminderDecision {
        ReminderDecision(
            showOverlay: trigger.showOverlay,
            sendNotification: trigger.sendNotification,
            playVoice: trigger.playVoice,
            escalateOverlay: false
        )
    }

    static let suppressAll = ReminderDecision(
        showOverlay: false,
        sendNotification: false,
        playVoice: false,
        escalateOverlay: false
    )
}

/// User-controllable toggles for the four context rules. Persisted to UserDefaults
/// individually so toggling one doesn't risk overwriting another.
@MainActor
final class SmartConfigManager: ObservableObject {

    @Published var suppressWhenInCall: Bool {
        didSet { UserDefaults.standard.set(suppressWhenInCall, forKey: Self.k_suppressWhenInCall) }
    }
    @Published var visualOnlyWhenFocus: Bool {
        didSet { UserDefaults.standard.set(visualOnlyWhenFocus, forKey: Self.k_visualOnlyWhenFocus) }
    }
    @Published var noVoiceWhenScreenSharing: Bool {
        didSet { UserDefaults.standard.set(noVoiceWhenScreenSharing, forKey: Self.k_noVoiceWhenScreenSharing) }
    }
    @Published var escalateWhenFullscreen: Bool {
        didSet { UserDefaults.standard.set(escalateWhenFullscreen, forKey: Self.k_escalateWhenFullscreen) }
    }

    init() {
        let d = UserDefaults.standard
        self.suppressWhenInCall = d.object(forKey: Self.k_suppressWhenInCall) as? Bool ?? true
        self.visualOnlyWhenFocus = d.object(forKey: Self.k_visualOnlyWhenFocus) as? Bool ?? true
        self.noVoiceWhenScreenSharing = d.object(forKey: Self.k_noVoiceWhenScreenSharing) as? Bool ?? true
        self.escalateWhenFullscreen = d.object(forKey: Self.k_escalateWhenFullscreen) as? Bool ?? false
    }

    private static let k_suppressWhenInCall = "smart_suppressWhenInCall"
    private static let k_visualOnlyWhenFocus = "smart_visualOnlyWhenFocus"
    private static let k_noVoiceWhenScreenSharing = "smart_noVoiceWhenScreenSharing"
    private static let k_escalateWhenFullscreen = "smart_escalateWhenFullscreen"
}

/// Pure decision function. Given a trigger config, the live context snapshot, and the
/// user's Smart toggles, returns what each channel should do for this firing.
///
/// Order matters: we evaluate the most aggressive suppression first (in-a-call) and the
/// most permissive escalation last. A rule is a no-op when its toggle is off.
enum ReminderEscalationPolicy {
    @MainActor
    static func decide(
        trigger: CountdownTrigger,
        context: MeetingContextSnapshot,
        config: SmartConfigManager
    ) -> ReminderDecision {
        if config.suppressWhenInCall && context.isInActiveCall {
            return .suppressAll
        }
        if config.visualOnlyWhenFocus && context.isFocusActive {
            return ReminderDecision(
                showOverlay: trigger.showOverlay,
                sendNotification: false,
                playVoice: false,
                escalateOverlay: false
            )
        }
        if config.noVoiceWhenScreenSharing && context.isScreenCaptured {
            return ReminderDecision(
                showOverlay: trigger.showOverlay,
                sendNotification: trigger.sendNotification,
                playVoice: false,
                escalateOverlay: false
            )
        }
        if config.escalateWhenFullscreen && context.isFullscreenAppActive {
            return ReminderDecision(
                showOverlay: trigger.showOverlay,
                sendNotification: trigger.sendNotification,
                playVoice: trigger.playVoice,
                escalateOverlay: true
            )
        }
        return .fromTrigger(trigger)
    }
}
