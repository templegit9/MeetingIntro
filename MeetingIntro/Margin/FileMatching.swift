import Foundation

/// Which files a tool is talking about.
///
/// Every file tool takes the same shape, so "the PDFs in Downloads older than a year"
/// means the same thing whether it is being found, moved or trashed. One matcher also
/// means one place where the rails live: **it never leaves a granted root, it never
/// descends into a package, and it never returns a partial download.**
struct FileMatch {
    var query: String?
    var extensions: [String] = []
    var folder: URL?
    var newerThan: Date?
    var olderThan: Date?
    var largerThanMB: Double?
    var limit: Int = 50
    /// Look inside subfolders too. Off by default — "the files in Downloads" means the
    /// ones you can see there, not the two thousand under them.
    var recursive = false

    /// Temp and partial files. Grabbing a half-finished download is the kind of mistake
    /// that loses someone's file, and `FileOrganizer` already learned this one.
    static let skippedExtensions: Set<String> = ["part", "crdownload", "download", "tmp", "temp"]

    func matches(_ url: URL, attributes: URLResourceValues) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") { return false }
        let ext = url.pathExtension.lowercased()
        if Self.skippedExtensions.contains(ext) { return false }
        if !extensions.isEmpty, !extensions.contains(ext) { return false }
        if let query, !query.isEmpty,
           !name.localizedCaseInsensitiveContains(query) { return false }
        if let newerThan, let modified = attributes.contentModificationDate, modified < newerThan { return false }
        if let olderThan, let modified = attributes.contentModificationDate, modified > olderThan { return false }
        if let largerThanMB, Double(attributes.fileSize ?? 0) < largerThanMB * 1_048_576 { return false }
        return true
    }
}

/// A file found, with the facts a page needs to show about it.
struct FoundFile: Identifiable, Equatable {
    let url: URL
    let size: Int
    let modified: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folderName: String { url.deletingLastPathComponent().lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    var whenText: String {
        modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
    }
}

/// Walks granted folders and returns what matches.
enum FileFinder {

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey,
                                         .contentModificationDateKey, .isRegularFileKey]

    /// Files matching `match` under `roots`. Sorted newest first, because a search for
    /// "that thing I downloaded" almost always means the recent one.
    static func find(_ match: FileMatch, in roots: [URL]) -> [FoundFile] {
        var found: [FoundFile] = []
        for root in roots {
            found.append(contentsOf: walk(root, match: match))
        }
        return found
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(match.limit)
            .map { $0 }
    }

    private static func walk(_ directory: URL, match: FileMatch) -> [FoundFile] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        // A .app or .rtfd is one thing to a person, not a folder to walk into.
        options.insert(.skipsPackageDescendants)
        if !match.recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: keys,
                                             options: options) else { return [] }
        var out: [FoundFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true || values.isPackage == true { continue }
            guard values.isRegularFile == true, match.matches(url, attributes: values) else { continue }
            out.append(FoundFile(url: url, size: values.fileSize ?? 0,
                                 modified: values.contentModificationDate))
            // Bounded: a recursive walk of a big tree must not run forever, and a page
            // can't show more than a few dozen lines anyway.
            if out.count >= match.limit * 4 { break }
        }
        return out
    }

    /// Read the shape of a `FileMatch` out of model arguments — one place, so every tool
    /// understands the same words.
    @MainActor
    static func selector(from arguments: [String: Any], roots: MarginRoots) -> (match: FileMatch, folder: URL?, missing: String?) {
        var match = FileMatch()
        match.query = ToolArgs.string(arguments, "query")
        match.extensions = ToolArgs.strings(arguments, "ext").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        }
        match.limit = min(max(ToolArgs.int(arguments, "limit") ?? 40, 1), 200)
        match.recursive = ToolArgs.bool(arguments, "recursive") ?? false
        if let days = ToolArgs.int(arguments, "newer_than_days") {
            match.newerThan = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        if let days = ToolArgs.int(arguments, "older_than_days") {
            match.olderThan = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        if let mb = ToolArgs.int(arguments, "larger_than_mb") { match.largerThanMB = Double(mb) }

        let named = ToolArgs.string(arguments, "folder")
        if let folder = roots.resolve(named) {
            match.folder = folder
            return (match, folder, nil)
        }
        // Not granted. Every tool turns this into an ask, never a silent empty result.
        return (match, nil, named ?? "")
    }
}
