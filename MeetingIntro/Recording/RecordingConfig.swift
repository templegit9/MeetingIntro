import Combine
import Foundation

/// User-controllable settings for auto-recording. Three booleans + an optional
/// security-scoped bookmark for a non-default save directory.
///
/// - `hasAcceptedDisclaimer` persists across off/on toggles so the disclaimer
///   modal only appears once.
/// - `saveDirectoryBookmark` is nil when the user is using the default
///   `~/Movies/MeetingIntro/`; non-nil when they've picked a custom folder.
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

    /// Resolves the save directory URL. Falls back to `~/Movies/MeetingIntro/` when no
    /// bookmark is set. Resolving the bookmark also re-starts security-scoped access —
    /// callers are responsible for `stopAccessingSecurityScopedResource()` when done.
    func resolveSaveDirectory() -> URL {
        if let bookmark = saveDirectoryBookmark,
           let url = Self.resolveBookmark(bookmark) {
            return url
        }
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
