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

/// Make a folder.
///
/// Trivial next to the others, and worth having as its own tool anyway: "make me an
/// Invoices folder" shouldn't have to be expressed as a move of zero files.
struct CreateFolderTool: AgentTool {
    let name = "create_folder"
    let description = "Create a new folder. Use for 'make an Invoices folder in Downloads', 'create a 2026 folder'."
    var humanSummary: String { "make a folder" }
    var parameters: [String: Any] {
        Self.schema([
            "name": Self.string("Name of the folder to create"),
            "parent": Self.string("Folder to create it inside")
        ], required: ["name"])
    }

    let roots: MarginRoots

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let rawName = ToolArgs.string(arguments, "name") else {
            throw ToolArgumentError(message: "What should the folder be called?")
        }
        let named = ToolArgs.string(arguments, "parent")
        guard let parent = roots.resolve(named) else {
            return FilePages.notGranted(named ?? "", roots: roots)
        }
        // A name with a slash in it would silently create a nested path — or escape the
        // parent entirely with "..". Sanitise to a single component.
        let folderName = FileNames.sanitizeComponent(rawName)
        guard !folderName.isEmpty else {
            throw ToolArgumentError(message: "“\(rawName)” isn't a usable folder name.")
        }
        let target = parent.appendingPathComponent(folderName, isDirectory: true)

        if FileManager.default.fileExists(atPath: target.path) {
            return ProposedAction(
                kind: .answer, title: "Already there",
                details: ["\(folderName) already exists in \(parent.lastPathComponent)."],
                provenance: "Nothing was created.", run: { _ in "" })
        }
        return ProposedAction(
            kind: .change,
            title: "Create folder",
            details: ["\(folderName) in \(parent.lastPathComponent)"],
            confirmLabel: "Create",
            run: { _ in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                return "Created \(folderName)."
            },
            undo: {
                // Only if it's still empty — undo must never take something away that was
                // put there after the fact.
                let contents = try? FileManager.default.contentsOfDirectory(atPath: target.path)
                if contents?.isEmpty ?? false { try? FileManager.default.removeItem(at: target) }
            })
    }
}

/// Rename a matched set by a pattern.
struct RenameFilesTool: AgentTool {
    let name = "rename_files"
    let description = "Rename files by a pattern. Use for 'prefix these with the date', 'replace IMG_ with Holiday', 'make these names lowercase'. Renames only — never moves or deletes."
    var humanSummary: String { "rename files by a pattern" }
    var parameters: [String: Any] {
        Self.schema([
            "query": Self.string("Text the file name should contain"),
            "ext": Self.stringArray("Extensions, without the dot"),
            "folder": Self.string("Folder the files are in"),
            "older_than_days": Self.integer("Only files older than this many days"),
            "newer_than_days": Self.integer("Only files changed within this many days"),
            "style": Self.string("One of: date_prefix, lowercase, kebab, replace"),
            "find": Self.string("Text to replace, when style is replace"),
            "replace_with": Self.string("Replacement text, when style is replace"),
            "limit": Self.integer("Cap on how many to rename. Default 100.")
        ], required: ["style"])
    }

    let roots: MarginRoots

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        var (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }
        match.limit = min(max(ToolArgs.int(arguments, "limit") ?? 100, 1), 500)

        guard let style = RenameStyle(arguments: arguments) else {
            throw ToolArgumentError(message: "I don't know that renaming style. I can add a date prefix, lowercase, kebab-case, or replace one piece of text with another.")
        }

        let files = FileFinder.find(match, in: [folder])
        // Only the ones the pattern actually changes. Listing files whose name would be
        // identical afterwards pads the page and overstates what is happening.
        let renames = files.compactMap { file -> (FoundFile, String)? in
            let proposed = style.apply(to: file)
            return proposed == file.name ? nil : (file, proposed)
        }
        guard !renames.isEmpty else {
            return ProposedAction(
                kind: .answer, title: "Nothing to rename",
                details: files.isEmpty
                    ? ["No files in \(folder.lastPathComponent) match that."]
                    : ["All \(files.count) matching file\(files.count == 1 ? "" : "s") already read that way."],
                provenance: FindFilesTool.provenance(folder: folder, match: match, count: files.count),
                run: { _ in "" })
        }

        var details = renames.prefix(MoveFilesTool.listCap).map { "\($0.0.name) → \($0.1)" }
        if renames.count > MoveFilesTool.listCap {
            details.append("+ \(renames.count - MoveFilesTool.listCap) more")
        }

        return ProposedAction(
            kind: .change,
            title: "Rename \(renames.count) file\(renames.count == 1 ? "" : "s") · \(style.label)",
            details: details,
            confirmLabel: "Rename \(renames.count)",
            run: { _ in
                var done: [MoveRecord] = []
                for (file, newName) in renames {
                    let target = MoveFilesTool.uniqueURL(in: file.url.deletingLastPathComponent(),
                                                         fileName: newName)
                    do {
                        try FileManager.default.moveItem(at: file.url, to: target)
                        done.append(MoveRecord(from: file.url, to: target))
                    } catch { continue }
                }
                Self.lastBatch = done
                return "Renamed \(done.count) file\(done.count == 1 ? "" : "s")."
            },
            undo: {
                let batch = Self.lastBatch
                Self.lastBatch = []
                for record in batch.reversed() {
                    try? FileManager.default.moveItem(at: record.to, to: record.from)
                }
            })
    }

    @MainActor private static var lastBatch: [MoveRecord] = []
}

/// The renaming patterns Margin offers.
///
/// A closed set, for the same reason `DraftRecurrence` is: a free-form pattern language
/// would be impossible to preview honestly, and the preview is the whole safety model.
enum RenameStyle {
    case datePrefix
    case lowercase
    case kebab
    case replace(find: String, with: String)

    init?(arguments: [String: Any]) {
        switch ToolArgs.string(arguments, "style")?.lowercased() {
        case "date_prefix", "dateprefix", "date": self = .datePrefix
        case "lowercase", "lower": self = .lowercase
        case "kebab", "kebab_case", "slug": self = .kebab
        case "replace":
            guard let find = ToolArgs.string(arguments, "find"), !find.isEmpty else { return nil }
            self = .replace(find: find, with: ToolArgs.string(arguments, "replace_with") ?? "")
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .datePrefix: return "date prefix"
        case .lowercase: return "lowercase"
        case .kebab: return "kebab-case"
        case .replace(let find, let with): return with.isEmpty ? "remove “\(find)”" : "“\(find)” → “\(with)”"
        }
    }

    /// The extension is never touched — renaming `report.pdf` to `report.PDF` or losing
    /// the suffix entirely would change what opens the file.
    func apply(to file: FoundFile) -> String {
        let base = (file.name as NSString).deletingPathExtension
        let ext = (file.name as NSString).pathExtension
        var renamed: String
        switch self {
        case .datePrefix:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let stamp = formatter.string(from: file.modified ?? Date())
            renamed = base.hasPrefix(stamp) ? base : "\(stamp) \(base)"
        case .lowercase:
            renamed = base.lowercased()
        case .kebab:
            renamed = base.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        case .replace(let find, let with):
            renamed = base.replacingOccurrences(of: find, with: with, options: .caseInsensitive)
        }
        renamed = FileNames.sanitizeComponent(renamed)
        if renamed.isEmpty { return file.name }
        return ext.isEmpty ? renamed : "\(renamed).\(ext)"
    }
}

/// Name hygiene shared by the tools that produce names.
enum FileNames {
    /// One path component, with everything that could escape it removed. `/` would create
    /// a nested path and `..` would climb out of the granted root entirely.
    static func sanitizeComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "")
            // Path-ish debris, collapsed rather than merely made harmless: "../../etc"
            // has no business surviving as "-..-etc" in a file name either.
            .replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^[.\\-\\s]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .prefix(120)
            .description
    }
}
