import Combine
import Foundation

/// User-controllable settings for auto-recording. Three booleans + an optional
/// security-scoped bookmark for a non-default save directory.
///
/// - `hasAcceptedDisclaimer` persists across off/on toggles so the disclaimer
///   modal only appears once.
/// - `saveDirectoryBookmark` is nil when the user is using the default
///   `~/Movies/MeetingIntro/`; non-nil when they've picked a custom folder.
///
/// **There is no default under the sandbox (App Store build).** `.moviesDirectory`
/// inside a sandbox resolves to `~/Library/Containers/<id>/Data/Movies`, which the user
/// cannot reach in Finder — App Review rejected 2.20.6 under guideline 2.4.5(i) for
/// exactly that ("the container is not for user documents"). So `resolveSaveDirectory()`
/// returns nil in the MAS build until the user picks a folder, and recording refuses to
/// start rather than writing somewhere invisible.
@MainActor
final class RecordingConfig: ObservableObject {

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.k_isEnabled) }
    }

    @Published var hasAcceptedDisclaimer: Bool {
        didSet { UserDefaults.standard.set(hasAcceptedDisclaimer, forKey: Self.k_hasAcceptedDisclaimer) }
    }

    @Published var saveDirectoryBookmark: Data? {
        didSet { UserDefaults.standard.set(saveDirectoryBookmark, forKey: Self.k_saveDirBookmark) }
    }

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: Self.k_isEnabled)
        self.hasAcceptedDisclaimer = d.bool(forKey: Self.k_hasAcceptedDisclaimer)
        self.saveDirectoryBookmark = d.data(forKey: Self.k_saveDirBookmark)
    }

    /// True when the build has no implicit save location and the user must choose one.
    /// Sandboxed (App Store) builds only — see the type comment.
    static var requiresChosenDirectory: Bool {
        #if MAS
        true
        #else
        false
        #endif
    }

    /// Resolves the save directory URL. Resolving the bookmark also re-starts
    /// security-scoped access — callers are responsible for
    /// `stopAccessingSecurityScopedResource()` when done.
    ///
    /// Returns nil **only** in the MAS build when the user hasn't picked a folder yet.
    /// The Developer ID build keeps its `~/Movies/MeetingIntro/` default, which is a real
    /// user-visible folder there because that build isn't sandboxed.
    func resolveSaveDirectory() -> URL? {
        if let bookmark = saveDirectoryBookmark,
           let url = Self.resolveBookmark(bookmark) {
            return url
        }
        if Self.requiresChosenDirectory { return nil }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("MeetingIntro", isDirectory: true)
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private static let k_isEnabled = "recording_isEnabled"
    private static let k_hasAcceptedDisclaimer = "recording_hasAcceptedDisclaimer"
    private static let k_saveDirBookmark = "recording_saveDirectoryBookmark"
}
