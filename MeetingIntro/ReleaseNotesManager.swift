import Combine
import Foundation

/// Fetches release notes from the public GitHub Releases API so the Settings
/// "What's New" section always shows current changelogs without requiring an app
/// update. The release script auto-generates a "What's changed since <prev>"
/// section per release; we surface that and strip the install instructions
/// (irrelevant to someone already running the app).
///
/// Unauthenticated GitHub API allows 60 requests/hour per IP — far more than we
/// need. The last good response is cached in UserDefaults so the view renders
/// offline and we only refetch when the cache is older than an hour.
@MainActor
final class ReleaseNotesManager: ObservableObject {

    struct Release: Codable, Identifiable {
        let tagName: String
        let publishedAt: Date
        let body: String

        var id: String { tagName }

        /// The changelog portion of the release body — everything before the
        /// "## Install" boilerplate.
        var changelog: String {
            let trimmed = body.components(separatedBy: "## Install").first ?? body
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case body
        }
    }

    @Published private(set) var releases: [Release] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let cacheKey = "releaseNotesCache"
    private static let cacheDateKey = "releaseNotesCacheDate"
    private static let cacheMaxAge: TimeInterval = 3600
    private static let apiURL = URL(string: "https://api.github.com/repos/templegit9/MeetingIntro/releases?per_page=20")!

    init() {
        loadFromCache()
    }

    /// Refresh from the API if the cache is stale (or `force` is set).
    func refreshIfNeeded(force: Bool = false) async {
        let cacheAge = Date().timeIntervalSince(
            UserDefaults.standard.object(forKey: Self.cacheDateKey) as? Date ?? .distantPast
        )
        guard force || releases.isEmpty || cacheAge > Self.cacheMaxAge else { return }

        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Couldn't load release notes (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            releases = try decoder.decode([Release].self, from: data)
            errorMessage = nil
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(Date(), forKey: Self.cacheDateKey)
        } catch {
            // Keep showing the cached notes; only surface the error when we have nothing.
            if releases.isEmpty {
                errorMessage = "Couldn't load release notes: \(error.localizedDescription)"
            }
        }
    }

    private func loadFromCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        releases = (try? decoder.decode([Release].self, from: data)) ?? []
    }
}
