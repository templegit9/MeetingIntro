import AppKit
import Foundation

/// The folders Margin is allowed to touch.
///
/// **This is the rail the whole file half hangs off.** The app is not App-Sandboxed, so it
/// could reach most of the disk and let macOS prompt as it went. That is exactly what makes
/// an explicit list worth having: an assistant that can read anywhere is one you cannot
/// reason about. A root is granted once, deliberately, through the system picker, and it
/// is revocable on the inside cover.
///
/// Bookmarks are security-scoped and stored as `Data`, never as paths — a path stops being
/// permission the moment the folder is renamed or moved, and the bookmark follows it.
@MainActor
final class MarginRoots: ObservableObject {

    struct Root: Identifiable, Equatable {
        let id: String
        let url: URL
        var name: String { url.lastPathComponent }
        var path: String { url.path(percentEncoded: false) }
    }

    @Published private(set) var roots: [Root] = []

    private static let key = "margin_roots"
    /// Resolved URLs currently holding a security scope, so it can be released on removal.
    private var scoped: [String: URL] = [:]

    init() { resolveAll() }

    // MARK: Granting

    /// Ask for a folder. The picker IS the grant — there is no way to add a root that the
    /// user didn't choose in a system panel, which is the point.
    @discardableResult
    func grant() -> Root? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant"
        panel.message = "Choose a folder Margin may work in. It can read, move and Trash inside this folder — nothing outside it."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return add(url)
    }

    @discardableResult
    func add(_ url: URL) -> Root? {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return nil }
        var stored = storedBookmarks()
        stored.append(bookmark)
        UserDefaults.standard.set(stored, forKey: Self.key)
        resolveAll()
        return roots.first { Self.sameFolder($0.url, url) }
    }

    func remove(_ root: Root) {
        var stored = storedBookmarks()
        stored.removeAll { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
            return Self.sameFolder(url, root.url)
        }
        UserDefaults.standard.set(stored, forKey: Self.key)
        if let url = scoped.removeValue(forKey: root.id) { url.stopAccessingSecurityScopedResource() }
        resolveAll()
    }

    /// Paths must be compared **after resolving symlinks**, not merely standardized.
    /// `/var/folders/…` is a symlink to `/private/var/folders/…`, `/tmp` to `/private/tmp`,
    /// and a home directory can be a link too — so a root granted by one name silently
    /// failed to match a query by the other. That bug made `add` report failure on a
    /// grant that had actually succeeded, and would have made `isGranted` refuse a folder
    /// the user really had granted.
    private static func canonical(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        canonical(a) == canonical(b)
    }

    // MARK: Asking

    /// Is this path inside something granted? Compared on path components, so `/Users/x/Doc`
    /// does not match `/Users/x/Documents` — a prefix test on strings would.
    func isGranted(_ url: URL) -> Bool { root(containing: url) != nil }

    func root(containing url: URL) -> Root? {
        let target = Self.canonical(url)
        return roots.first { root in
            let base = Self.canonical(root.url)
            return target.count >= base.count && Array(target.prefix(base.count)) == base
        }
    }

    /// Resolve a folder the model named — "Downloads", "~/Desktop", a full path — to a
    /// granted root. Returns nil when it isn't granted, which every tool reports as an ask
    /// rather than an error.
    func resolve(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return roots.count == 1 ? roots[0].url : nil }
        let expanded = URL(fileURLWithPath: (name as NSString).expandingTildeInPath).standardizedFileURL
        if expanded.pathComponents.count > 1, isGranted(expanded) { return expanded }
        // A bare name — "Downloads" — matches a granted root, or a folder directly inside one.
        let needle = name.lowercased()
        if let root = roots.first(where: { $0.name.lowercased() == needle }) { return root.url }
        for root in roots {
            let child = root.url.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: child.path) { return child }
        }
        return nil
    }

    /// Human list for a page's evidence line.
    var summary: String {
        roots.isEmpty ? "no folders granted yet" : roots.map(\.name).joined(separator: ", ")
    }

    // MARK: Storage

    private func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
    }

    private func resolveAll() {
        var resolved: [Root] = []
        var refreshed: [Data] = []
        for data in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            // Holding the scope for the app's lifetime: these are folders the user granted
            // on purpose, and re-acquiring per operation would drop access mid-run.
            if scoped[url.path] == nil, url.startAccessingSecurityScopedResource() {
                scoped[url.path] = url
            }
            resolved.append(Root(id: url.path, url: url))
            // A stale bookmark still resolves; re-minting it keeps it working next launch.
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                refreshed.append(fresh)
            } else {
                refreshed.append(data)
            }
        }
        if refreshed.count == storedBookmarks().count, refreshed != storedBookmarks() {
            UserDefaults.standard.set(refreshed, forKey: Self.key)
        }
        roots = resolved
    }
}
