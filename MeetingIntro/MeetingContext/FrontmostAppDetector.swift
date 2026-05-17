import AppKit
import Combine

/// Tracks which app is currently frontmost and whether it is a known video-conferencing app
/// or running fullscreen on the main display.
///
/// Push-driven via `NSWorkspace.didActivateApplicationNotification`. The fullscreen check
/// runs on each activation by inspecting the frontmost app's windows via `CGWindowList`.
@MainActor
final class FrontmostAppDetector: ObservableObject {

    @Published private(set) var frontmostBundleID: String?
    @Published private(set) var isConferenceAppActive: Bool = false
    @Published private(set) var isFullscreenAppActive: Bool = false

    /// Bundle identifiers of apps we treat as definitive "you are in a meeting" signals.
    /// Chrome and other browsers are NOT here — the mic-in-use detector handles browser-based calls.
    private static let conferenceBundleIDs: Set<String> = [
        "us.zoom.xos",
        "ZoomChat",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webex.meetings",
        "com.logmein.GoToMeeting",
    ]

    private var observer: Any?

    init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func refresh() {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        frontmostBundleID = bundleID
        isConferenceAppActive = bundleID.map { Self.conferenceBundleIDs.contains($0) } ?? false
        isFullscreenAppActive = Self.checkFullscreen(for: app)
    }

    /// Detects whether the frontmost app has a window matching the main display's frame.
    /// `CGWindowList` is a public API and requires no entitlement.
    private static func checkFullscreen(for app: NSRunningApplication?) -> Bool {
        guard let pid = app?.processIdentifier,
              let screen = NSScreen.main else { return false }
        let screenFrame = screen.frame
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in windowList {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? Int32, ownerPid == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            // Match within 2pt tolerance — menu bar inclusion varies slightly between APIs.
            if abs(bounds.width - screenFrame.width) < 2 && abs(bounds.height - screenFrame.height) < 2 {
                return true
            }
        }
        return false
    }
}
