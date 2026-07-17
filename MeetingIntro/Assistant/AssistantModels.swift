import Foundation

/// A saved folder the Executive Assistant can organize (Issue #17). v1 is manual
/// ("Organize now"); v2 adds schedule/watch fields.
struct OrganizeJob: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    /// Security-scoped bookmark of the folder to organize (created via NSOpenPanel).
    var sourceBookmark: Data? = nil
    /// Propose cleaner filenames in addition to foldering.
    var renameEnabled: Bool = true
    /// v1 always previews; kept for v2 automation (default off = preview-first).
    var autoApply: Bool = false
}

/// Metadata + a short content preview of one file, fed to the model for classification.
struct FilePreview {
    let url: URL
    let name: String
    let ext: String
    let sizeBytes: Int
    let modified: Date?
    /// Text extracted for classification (head+tail of text files, PDF first page),
    /// nil for images/binaries.
    let contentPreview: String?
}

/// One proposed action from the model — where a file should go and (optionally) its new
/// name, each with a human-readable reason surfaced in the preview.
struct FileProposal: Identifiable {
    let id = UUID()
    let originalURL: URL
    var proposedFolder: String
    /// Includes the extension. Equals the original name when no rename is proposed.
    var proposedName: String
    var observedReason: String
    var renameReason: String
    var include: Bool = true

    var willRename: Bool { proposedName != originalURL.lastPathComponent }
}

/// A single applied move (persisted for undo).
struct FileMove: Codable, Equatable {
    let from: String   // absolute path before
    let to: String     // absolute path after
}

/// An applied organize run — the record used to revert it.
struct UndoBatch: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var jobName: String
    var timestamp: Date
    var moves: [FileMove]
    /// Folders the run created (removed on undo if they end up empty).
    var createdFolders: [String]
}
