import AppKit
import Foundation

/// Moving and trashing — the first tools that change the disk.
///
/// Both follow the rail the File Organizer already proved: **preview every affected file,
/// confirm, and keep an exact undo.** Neither can act outside a granted root, and neither
/// deletes: `trash_files` uses the Trash, which the user can also empty or restore from
/// without the app.

/// One completed move, kept so it can be reversed exactly.
private struct MoveRecord {
    let from: URL
    let to: URL
}

/// Move a matched set into a folder.
struct MoveFilesTool: AgentTool {
    let name = "move_files"
    let description = "Move files into a folder. Use for 'move the dmgs into Installers', 'put last month's invoices in Archive'. Never deletes anything."
    var humanSummary: String { "move files into a folder" }
    var parameters: [String: Any] {
        Self.schema([
            "query": Self.string("Text the file name should contain"),
            "ext": Self.stringArray("Extensions, without the dot"),
            "folder": Self.string("Folder the files are in now"),
            "destination": Self.string("Folder to move them into. Created inside the source folder if it doesn't exist."),
            "older_than_days": Self.integer("Only files older than this many days"),
            "newer_than_days": Self.integer("Only files changed within this many days"),
            "larger_than_mb": Self.integer("Only files bigger than this"),
            "recursive": Self.boolean("Include subfolders. Default false."),
            "limit": Self.integer("Cap on how many to move. Default 100.")
        ], required: ["destination"])
    }

    let roots: MarginRoots
    /// A move nobody could read before approving isn't really approved. Past this many
    /// files the page shows the first few and says how many more.
    static let listCap = 12

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let destinationName = ToolArgs.string(arguments, "destination") else {
            throw ToolArgumentError(message: "Move them where?")
        }
        var (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }
        match.limit = min(max(ToolArgs.int(arguments, "limit") ?? 100, 1), 500)

        // A destination inside the source folder is the common case ("into Installers").
        // An absolute path is honoured only if it is itself granted.
        let destination = roots.resolve(destinationName)
            ?? folder.appendingPathComponent(destinationName, isDirectory: true)
        guard roots.isGranted(destination) else {
            return FilePages.notGranted(destinationName, roots: roots)
        }

        let files = FileFinder.find(match, in: [folder])
        guard !files.isEmpty else {
            return ProposedAction(kind: .answer, title: "Nothing to move",
                                  details: ["No files in \(folder.lastPathComponent) match that."],
                                  provenance: FindFilesTool.provenance(folder: folder, match: match, count: 0),
                                  run: { _ in "" })
        }

        var details = files.prefix(Self.listCap).map { "\($0.name) · \($0.sizeText)" }
        if files.count > Self.listCap { details.append("+ \(files.count - Self.listCap) more") }

        var warnings: [String] = []
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if !exists { warnings.append("\(destination.lastPathComponent) doesn't exist yet — I'll create it") }
        if files.count > 50 { warnings.append("That's \(files.count) files in one move") }

        return ProposedAction(
            kind: .change,
            title: "Move \(files.count) file\(files.count == 1 ? "" : "s") → \(destination.lastPathComponent)",
            details: details,
            warnings: warnings,
            confirmLabel: "Move \(files.count)",
            run: { _ in
                let moves = try Self.perform(files: files, into: destination)
                Self.lastBatch = moves
                return "Moved \(moves.count) file\(moves.count == 1 ? "" : "s") into \(destination.lastPathComponent)."
            },
            undo: {
                let moves = Self.lastBatch
                Self.lastBatch = []
                for move in moves.reversed() {
                    try? FileManager.default.moveItem(at: move.to, to: move.from)
                }
            })
    }

    /// Kept so undo can put every file back exactly where it was, including any that were
    /// renamed to avoid a collision.
    @MainActor private static var lastBatch: [MoveRecord] = []

    private static func perform(files: [FoundFile], into destination: URL) throws -> [MoveRecord] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        var done: [MoveRecord] = []
        for file in files {
            let target = uniqueURL(in: destination, fileName: file.name)
            do {
                try fm.moveItem(at: file.url, to: target)
                done.append(MoveRecord(from: file.url, to: target))
            } catch {
                // One failure must not take the rest down, and it must not be silent: the
                // page reports how many actually moved.
                continue
            }
        }
        return done
    }

    /// Never overwrite. A move that silently replaced a file would be a deletion by
    /// another name.
    static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

/// Move a matched set to the Trash.
struct TrashFilesTool: AgentTool {
    let name = "trash_files"
    let description = "Move files to the Trash. Use for 'bin the old installers', 'clear out screenshots from last year'. This is the Trash, not a permanent delete — the user can restore them."
    var humanSummary: String { "move files to the Trash (never a permanent delete)" }
    var parameters: [String: Any] {
        Self.schema([
            "query": Self.string("Text the file name should contain"),
            "ext": Self.stringArray("Extensions, without the dot"),
            "folder": Self.string("Folder the files are in"),
            "older_than_days": Self.integer("Only files older than this many days"),
            "larger_than_mb": Self.integer("Only files bigger than this"),
            "recursive": Self.boolean("Include subfolders. Default false."),
            "limit": Self.integer("Cap on how many to trash. Default 100.")
        ], required: [])
    }

    let roots: MarginRoots

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        var (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }
        match.limit = min(max(ToolArgs.int(arguments, "limit") ?? 100, 1), 500)

        // Trashing everything in a folder because no filter came through is the one
        // outcome this tool must never produce by accident.
        let hasFilter = match.query != nil || !match.extensions.isEmpty
            || match.olderThan != nil || match.newerThan != nil || match.largerThanMB != nil
        guard hasFilter else {
            return ProposedAction(
                kind: .answer, title: "Which files?",
                details: ["I won't Trash a whole folder on a vague instruction.",
                          "Tell me which ones — by name, kind, age or size."],
                provenance: "Nothing has been touched.",
                run: { _ in "" })
        }

        let files = FileFinder.find(match, in: [folder])
        guard !files.isEmpty else {
            return ProposedAction(kind: .answer, title: "Nothing to Trash",
                                  details: ["No files in \(folder.lastPathComponent) match that."],
                                  provenance: FindFilesTool.provenance(folder: folder, match: match, count: 0),
                                  run: { _ in "" })
        }

        var details = files.prefix(MoveFilesTool.listCap).map { "\($0.name) · \($0.sizeText)" }
        if files.count > MoveFilesTool.listCap {
            details.append("+ \(files.count - MoveFilesTool.listCap) more")
        }

        return ProposedAction(
            kind: .change,
            title: "Trash \(files.count) file\(files.count == 1 ? "" : "s") · \(FilePages.totalSize(files))",
            details: details,
            warnings: files.count > 50 ? ["That's \(files.count) files at once"] : [],
            confirmLabel: "Move \(files.count) to Trash",
            run: { _ in
                let trashed = Self.perform(files: files)
                Self.lastBatch = trashed
                return "Moved \(trashed.count) file\(trashed.count == 1 ? "" : "s") to the Trash."
            },
            undo: {
                let trashed = Self.lastBatch
                Self.lastBatch = []
                for record in trashed.reversed() {
                    try? FileManager.default.moveItem(at: record.to, to: record.from)
                }
            })
    }

    @MainActor private static var lastBatch: [MoveRecord] = []

    /// `trashItem` hands back where the file landed, which is what makes undo exact rather
    /// than "look in the Trash yourself".
    private static func perform(files: [FoundFile]) -> [MoveRecord] {
        var done: [MoveRecord] = []
        for file in files {
            var landed: NSURL?
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: &landed)
                if let landed = landed as URL? {
                    done.append(MoveRecord(from: file.url, to: landed))
                }
            } catch {
                continue
            }
        }
        return done
    }
}
