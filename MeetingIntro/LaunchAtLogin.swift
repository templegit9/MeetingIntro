import Foundation
import ServiceManagement

// SMAppService is the source of truth, not UserDefaults: the user can remove the
// login item in System Settings → General → Login Items, and the toggle must agree.
enum LaunchAtLogin {
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LaunchAtLogin: \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }

    // On by default, applied once, so a later opt-out in Settings or System Settings sticks.
    // Release only: registering a Debug build would add the DerivedData copy as a login item.
    static func applyDefaultOnce() {
        #if !DEBUG
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultAppliedKey) else { return }
        defaults.set(true, forKey: defaultAppliedKey)
        if SMAppService.mainApp.status == .notRegistered { set(true) }
        #endif
    }
}
