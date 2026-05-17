import Combine
import Foundation
import Intents

/// Reports whether the user has a Focus / Do Not Disturb mode active.
///
/// `INFocusStatusCenter` is Apple's only blessed public API for this. It is read-only;
/// we cannot toggle Focus from here — that's Phase 4's job, handled via Shortcuts.
///
/// The API requires user permission. If the user denies, we treat Focus as "off" and
/// surface a one-time banner in the Smart tab.
@MainActor
final class FocusModeDetector: ObservableObject {

    enum AuthorizationStatus {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    @Published private(set) var isFocusActive: Bool = false
    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined

    private var cancellable: AnyCancellable?

    init() {
        refreshAuthorization()
        refreshStatus()
        // INFocusStatusCenter does not publish change notifications, so we re-poll on a
        // 10-second cadence. Focus state changes are rare and not latency-sensitive.
        cancellable = Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
    }

    /// Requests authorization. Safe to call repeatedly — the system surfaces the prompt
    /// once and remembers the answer.
    func requestAuthorization() async {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<INFocusStatusAuthorizationStatus, Never>) in
            INFocusStatusCenter.default.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        authorizationStatus = Self.map(result)
        refreshStatus()
    }

    private func refreshAuthorization() {
        authorizationStatus = Self.map(INFocusStatusCenter.default.authorizationStatus)
    }

    private func refreshStatus() {
        guard authorizationStatus == .authorized else {
            isFocusActive = false
            return
        }
        isFocusActive = INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    private static func map(_ status: INFocusStatusAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
