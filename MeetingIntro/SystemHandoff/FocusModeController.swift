import AppKit
import Foundation
import Intents

/// Controls macOS Focus / Do Not Disturb by invoking user-installed Shortcuts.
///
/// Why Shortcuts: `INFocusStatusCenter` is read-only — there is no public API to
/// programmatically enable Focus from a sandboxed app. Shortcuts is Apple's blessed
/// escape hatch: the user installs two named Shortcuts once, and we trigger them
/// via the `shortcuts://run-shortcut?name=...` URL scheme. The OS handles the
/// permission boundary; we don't need an Automation entitlement.
@MainActor
final class FocusModeController {

    static let startShortcutName = "MeetingIntro – Start Focus"
    static let endShortcutName = "MeetingIntro – End Focus"

    /// Result of a verified shortcut invocation.
    enum Outcome: Equatable {
        /// Shortcut ran and `INFocusStatusCenter` confirms the new state within the timeout.
        case verified
        /// Shortcut URL was dispatched but the Focus state didn't change (most likely the user
        /// hasn't installed the named Shortcut, or it was renamed).
        case unverified
        /// Couldn't verify because the user hasn't granted Focus permission.
        case noFocusPermission
    }

    func enable() async -> Outcome {
        await invoke(named: Self.startShortcutName, expecting: true)
    }

    func disable() async -> Outcome {
        await invoke(named: Self.endShortcutName, expecting: false)
    }

    private func invoke(named name: String, expecting expectedFocused: Bool) async -> Outcome {
        guard let url = Self.runURL(name: name) else { return .unverified }
        NSWorkspace.shared.open(url)

        // Up to 3 seconds for the Shortcut to land. Most shortcuts complete <500ms.
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            switch INFocusStatusCenter.default.authorizationStatus {
            case .authorized:
                let actual = INFocusStatusCenter.default.focusStatus.isFocused ?? false
                if actual == expectedFocused { return .verified }
            default:
                return .noFocusPermission
            }
        }
        return .unverified
    }

    private static func runURL(name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }
}
