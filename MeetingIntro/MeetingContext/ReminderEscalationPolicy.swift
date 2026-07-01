import Combine
import Foundation

/// Why the policy downgraded a reminder's channels — surfaced in the diagnostic log so
/// a silent suppression ("notify=false overlay=false") isn't a black box, and used to
/// scope the in-call auto-release (only the `.inCall` mute is overridden by the cap).
enum ReminderSuppression: Equatable {
    case inCall, focus, screenSharing

    var logDescription: String {
        switch self {
        case .inCall:        return "on a call — mic in use"
        case .focus:         return "Focus on — visual only"
        case .screenSharing: return "screen sharing — voice off"
        }
    }
}

/// What the policy decided for a single reminder firing. The fields shadow the per-trigger
/// flags on `CountdownTrigger`; the policy may downgrade (e.g. turn off `playVoice` even
/// when the trigger requested it) but never upgrade beyond what the trigger asked for.
struct ReminderDecision: Equatable {
    var showOverlay: Bool
    var sendNotification: Bool
    var playVoice: Bool
    var escalateOverlay: Bool
    /// The context signal that reduced this decision's channels, if any (nil for a
    /// full-trigger firing or an escalation).
    var suppressedBy: ReminderSuppression? = nil

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
        escalateOverlay: false,
        suppressedBy: .inCall
    )
}

/// User-controllable toggles for the four context rules. Persisted to UserDefaults
/// individually so toggling one doesn't risk overwriting another.
@MainActor
final class SmartConfigManager: ObservableObject {

    @Published var suppressWhenInCall: Bool {
        didSet { UserDefaults.standard.set(suppressWhenInCall, forKey: Self.k_suppressWhenInCall) }
    }
    /// Auto-release the in-call mute after this many minutes of *continuous* detected
    /// call, so a stuck/held mic can't silently mute reminders forever (the v2.7.0-family
    /// failure). Default 30; `0` = never auto-release (a persistent stuck mic still
    /// surfaces via the legacy 90-min WARN).
    @Published var maxInCallSuppressionMinutes: Int {
        didSet { UserDefaults.standard.set(maxInCallSuppressionMinutes, forKey: Self.k_maxInCallSuppressionMinutes) }
    }
    /// When suppressing in a call, still deliver the (quiet) system notification so you
    /// know a meeting is imminent — only the overlay + voice are dropped (Issue #12).
    /// Off by default: the plain in-call rule stays full-silence unless you opt in.
    @Published var inCallStillNotify: Bool {
        didSet { UserDefaults.standard.set(inCallStillNotify, forKey: Self.k_inCallStillNotify) }
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

    /// RSVP gate: skip reminders + auto-record for invitations the user declined.
    /// On by default — the unambiguous win (no nagging about a meeting you bailed on).
    @Published var skipDeclinedMeetings: Bool {
        didSet { UserDefaults.standard.set(skipDeclinedMeetings, forKey: Self.k_skipDeclinedMeetings) }
    }
    /// Stricter opt-in: also skip invitations the user hasn't responded to. Off by
    /// default — risks silencing a meeting you simply forgot to accept.
    @Published var skipNoResponseMeetings: Bool {
        didSet { UserDefaults.standard.set(skipNoResponseMeetings, forKey: Self.k_skipNoResponseMeetings) }
    }

    init() {
        let d = UserDefaults.standard
        self.suppressWhenInCall = d.object(forKey: Self.k_suppressWhenInCall) as? Bool ?? true
        self.maxInCallSuppressionMinutes = d.object(forKey: Self.k_maxInCallSuppressionMinutes) as? Int ?? 30
        self.inCallStillNotify = d.object(forKey: Self.k_inCallStillNotify) as? Bool ?? false
        self.visualOnlyWhenFocus = d.object(forKey: Self.k_visualOnlyWhenFocus) as? Bool ?? true
        self.noVoiceWhenScreenSharing = d.object(forKey: Self.k_noVoiceWhenScreenSharing) as? Bool ?? true
        self.escalateWhenFullscreen = d.object(forKey: Self.k_escalateWhenFullscreen) as? Bool ?? false
        self.skipDeclinedMeetings = d.object(forKey: Self.k_skipDeclinedMeetings) as? Bool ?? true
        self.skipNoResponseMeetings = d.object(forKey: Self.k_skipNoResponseMeetings) as? Bool ?? false
    }

    /// Convenience for the gate sites — true if this event should go quiet.
    func suppresses(_ meeting: MeetingEvent) -> Bool {
        meeting.suppressedByResponse(skipDeclined: skipDeclinedMeetings,
                                     skipNoResponse: skipNoResponseMeetings)
    }

    private static let k_suppressWhenInCall = "smart_suppressWhenInCall"
    private static let k_maxInCallSuppressionMinutes = "smart_maxInCallSuppressionMinutes"
    private static let k_inCallStillNotify = "smart_inCallStillNotify"
    private static let k_visualOnlyWhenFocus = "smart_visualOnlyWhenFocus"
    private static let k_noVoiceWhenScreenSharing = "smart_noVoiceWhenScreenSharing"
    private static let k_escalateWhenFullscreen = "smart_escalateWhenFullscreen"
    private static let k_skipDeclinedMeetings = "smart_skipDeclinedMeetings"
    private static let k_skipNoResponseMeetings = "smart_skipNoResponseMeetings"
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
            // Opt-in (Issue #12): keep the (quiet) system notification so you still know a
            // meeting's coming, but drop the intrusive overlay + voice while you're on a call.
            if config.inCallStillNotify {
                return ReminderDecision(
                    showOverlay: false,
                    sendNotification: trigger.sendNotification,
                    playVoice: false,
                    escalateOverlay: false,
                    suppressedBy: .inCall
                )
            }
            return .suppressAll
        }
        if config.visualOnlyWhenFocus && context.isFocusActive {
            return ReminderDecision(
                showOverlay: trigger.showOverlay,
                sendNotification: false,
                playVoice: false,
                escalateOverlay: false,
                suppressedBy: .focus
            )
        }
        if config.noVoiceWhenScreenSharing && context.isScreenCaptured {
            return ReminderDecision(
                showOverlay: trigger.showOverlay,
                sendNotification: trigger.sendNotification,
                playVoice: false,
                escalateOverlay: false,
                suppressedBy: .screenSharing
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
