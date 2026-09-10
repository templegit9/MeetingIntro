import AppKit
import Foundation

/// Shared page-building for file answers, so every file tool states the same facts in the
/// same order: what it looked in, what it found, and what it could not reach.
enum FilePages {

    /// The ask that replaces a silent empty result. A folder Margin hasn't been granted is
    /// not "no files" — saying so is the difference between a tool that looks broken and
    /// one that tells you the next move.
    @MainActor
    static func notGranted(_ named: String, roots: MarginRoots) -> ProposedAction {
        let asked = named.isEmpty ? "that folder" : "“\(named)”"
        return ProposedAction(
            kind: .answer,
            title: "Not granted",
            details: roots.roots.isEmpty
                ? ["I can't see any folders yet.", "Grant one and I'll work inside it — and only inside it."]
                : ["I can't reach \(asked).", "I can work in: \(roots.summary)."],
            provenance: "Margin only reads and moves files inside folders you've granted.",
            confirmLabel: "Grant a folder…",
            run: { _ in
                guard let root = roots.grant() else { return "Nothing granted." }
                return "Granted \(root.name). Ask again and I'll look there."
            })
    }

    /// Files grouped by the folder they're in, newest first.
    static func groups(_ files: [FoundFile]) -> [PageGroup] {
        let byFolder = Dictionary(grouping: files) { $0.url.deletingLastPathComponent() }
        return byFolder.keys.sorted { $0.path < $1.path }.map { folder in
            PageGroup(id: folder.path, label: folder.lastPathComponent,
                      choices: (byFolder[folder] ?? []).map { file in
                          PageChoice(id: file.id, label: file.name,
                                     note: "\(file.sizeText) · \(file.whenText)")
                      })
        }
    }

    static func totalSize(_ files: [FoundFile]) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file)
    }
}

/// Find files by name, kind, age or size.
struct FindFilesTool: AgentTool {
    let name = "find_files"
    let description = "Find files by name, extension, age or size inside folders the user has granted. Use for 'find my invoices', 'what pdfs are in Downloads', 'anything big from last month'."
    var humanSummary: String { "find files by name, kind, age or size" }
    var parameters: [String: Any] {
        Self.schema([
            "query": Self.string("Text the file name should contain"),
            "ext": Self.stringArray("Extensions, without the dot — pdf, png, dmg"),
            "folder": Self.string("Folder to search. Omit to use the only granted folder."),
            "newer_than_days": Self.integer("Only files changed within this many days"),
            "older_than_days": Self.integer("Only files older than this many days"),
            "larger_than_mb": Self.integer("Only files bigger than this many megabytes"),
            "recursive": Self.boolean("Search subfolders too. Default false."),
            "limit": Self.integer("How many to return. Default 40.")
        ], required: [])
    }

    let roots: MarginRoots

    func workingPhrase(_ arguments: [String: Any]) -> String {
        let folder = ToolArgs.string(arguments, "folder")
        let kinds = ToolArgs.strings(arguments, "ext").map { ".\($0)" }.joined(separator: ", ")
        let what = kinds.isEmpty ? "files" : kinds
        return folder.map { "looking for \(what) in \($0)…" } ?? "looking for \(what)…"
    }

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        let (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }

        let files = FileFinder.find(match, in: [folder])
        guard !files.isEmpty else {
            return ProposedAction(
                kind: .answer, title: "Nothing found",
                details: ["No files in \(folder.lastPathComponent) match that."],
                provenance: Self.provenance(folder: folder, match: match, count: 0),
                run: { _ in "" })
        }
        return ProposedAction(
            kind: .answer,
            title: "\(files.count) file\(files.count == 1 ? "" : "s") · \(FilePages.totalSize(files))",
            groups: FilePages.groups(files),
            provenance: Self.provenance(folder: folder, match: match, count: files.count),
            confirmLabel: "Reveal in Finder",
            run: { picked in
                guard let picked else { return "Pick a file first." }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: picked)])
                return "Shown in Finder."
            })
    }

    static func provenance(folder: URL, match: FileMatch, count: Int) -> String {
        var parts = ["Looked in \(folder.lastPathComponent)\(match.recursive ? " and its subfolders" : " (not subfolders)")"]
        if !match.extensions.isEmpty { parts.append(match.extensions.map { ".\($0)" }.joined(separator: ", ")) }
        if match.olderThan != nil { parts.append("older files only") }
        if match.newerThan != nil { parts.append("recent files only") }
        parts.append("partial downloads skipped")
        return parts.joined(separator: " · ") + "."
    }
}

/// Search inside files — including screenshots and scans, via the OCR the File Organizer
/// already does.
struct FindByContentTool: AgentTool {
    let name = "find_files_by_content"
    let description = "Search INSIDE files for text, including PDFs and screenshots. Use when the user describes what a file says rather than what it is called — 'the invoice mentioning Acme', 'which screenshot has the error'."
    var humanSummary: String { "search inside files, including screenshots and PDFs" }
    var parameters: [String: Any] {
        Self.schema([
            "text": Self.string("Text to look for inside the files"),
            "folder": Self.string("Folder to search"),
            "ext": Self.stringArray("Limit to these extensions"),
            "limit": Self.integer("How many files to return. Default 12.")
        ], required: ["text"])
    }

    let roots: MarginRoots

    func workingPhrase(_ arguments: [String: Any]) -> String {
        let text = ToolArgs.string(arguments, "text") ?? "that"
        let folder = ToolArgs.string(arguments, "folder")
        return folder.map { "reading files in \($0) for “\(text)”…" } ?? "reading files for “\(text)”…"
    }

    /// Reading files is slow next to listing them, so the number opened is capped and the
    /// page says what the cap was. A search that silently stopped early is a lie.
    static let scanCap = 120

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let needle = ToolArgs.string(arguments, "text") else {
            throw ToolArgumentError(message: "What should I look for inside them?")
        }
        var (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }
        match.limit = Self.scanCap
        match.recursive = ToolArgs.bool(arguments, "recursive") ?? true

        let candidates = FileFinder.find(match, in: [folder])
        let wanted = min(max(ToolArgs.int(arguments, "limit") ?? 12, 1), 40)
        var hits: [FoundFile] = []
        var opened = 0
        for file in candidates {
            opened += 1
            let preview = FilePreviewExtractor.extract(file.url)
            if preview.contentPreview?.localizedCaseInsensitiveContains(needle) == true {
                hits.append(file)
                if hits.count >= wanted { break }
            }
        }

        let evidence = "Opened \(opened) of \(candidates.count) file\(candidates.count == 1 ? "" : "s") in \(folder.lastPathComponent) and read their text\(opened >= Self.scanCap ? " — stopped at \(Self.scanCap)" : "")."
        guard !hits.isEmpty else {
            return ProposedAction(kind: .answer, title: "No match",
                                  details: ["Nothing containing “\(needle)”."],
                                  provenance: evidence, run: { _ in "" })
        }
        return ProposedAction(
            kind: .answer,
            title: "\(hits.count) mention\(hits.count == 1 ? "" : "s") “\(needle)”",
            groups: FilePages.groups(hits),
            provenance: evidence,
            confirmLabel: "Reveal in Finder",
            run: { picked in
                guard let picked else { return "Pick a file first." }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: picked)])
                return "Shown in Finder."
            })
    }
}

/// What's actually in a folder.
struct FolderSummaryTool: AgentTool {
    let name = "folder_summary"
    let description = "Describe a folder: how many files, how big, what kinds, oldest and largest. Use for 'what's in my Downloads', 'how messy is this folder'."
    var humanSummary: String { "tell you what's in a folder and what's taking up room" }
    var parameters: [String: Any] {
        Self.schema(["folder": Self.string("Folder to describe"),
                     "recursive": Self.boolean("Include subfolders. Default false.")], required: [])
    }

    let roots: MarginRoots

    func workingPhrase(_ arguments: [String: Any]) -> String {
        "counting what's in \(ToolArgs.string(arguments, "folder") ?? "the folder")…"
    }

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        var (match, folder, missing) = FileFinder.selector(from: arguments, roots: roots)
        if let missing { return FilePages.notGranted(missing, roots: roots) }
        guard let folder else { return FilePages.notGranted("", roots: roots) }
        match.limit = 5000

        let files = FileFinder.find(match, in: [folder])
        guard !files.isEmpty else {
            return ProposedAction(kind: .answer, title: folder.lastPathComponent,
                                  details: ["Empty, as far as I can see."],
                                  provenance: "Looked in \(folder.lastPathComponent).", run: { _ in "" })
        }

        let byKind = Dictionary(grouping: files) { $0.url.pathExtension.lowercased() }
        let kinds = byKind.sorted { $0.value.count > $1.value.count }.prefix(5)
            .map { "\($0.value.count) ·\($0.key.isEmpty ? "no extension" : $0.key)" }
        let largest = files.max { $0.size < $1.size }
        let oldest = files.min { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }

        var details = ["\(files.count) files · \(FilePages.totalSize(files))"]
        details.append(kinds.joined(separator: ", "))
        if let largest { details.append("Largest: \(largest.name) · \(largest.sizeText)") }
        if let oldest, let date = oldest.modified {
            details.append("Oldest: \(oldest.name) · \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return ProposedAction(
            kind: .answer,
            title: folder.lastPathComponent,
            details: details,
            provenance: "Counted files in \(folder.lastPathComponent)\(match.recursive ? " and its subfolders" : " (not subfolders)").",
            run: { _ in "" })
    }
}

/// Where is that file?
struct WhereIsTool: AgentTool {
    let name = "where_is"
    let description = "Locate a file by name across every granted folder. Use for 'where is the offer letter', 'find blender.dmg'."
    var humanSummary: String { "find where a file is" }
    var parameters: [String: Any] {
        Self.schema(["name": Self.string("All or part of the file name")], required: ["name"])
    }

    let roots: MarginRoots

    func workingPhrase(_ arguments: [String: Any]) -> String {
        "searching every folder for “\(ToolArgs.string(arguments, "name") ?? "it")”…"
    }

    @MainActor func prepare(_ arguments: [String: Any]) async throws -> ProposedAction {
        guard let needle = ToolArgs.string(arguments, "name") else {
            throw ToolArgumentError(message: "What's it called?")
        }
        guard !roots.roots.isEmpty else { return FilePages.notGranted("", roots: roots) }

        var match = FileMatch()
        match.query = needle
        match.recursive = true
        match.limit = 25
        let files = FileFinder.find(match, in: roots.roots.map(\.url))

        guard !files.isEmpty else {
            return ProposedAction(kind: .answer, title: "Not found",
                                  details: ["Nothing called “\(needle)” in \(roots.summary)."],
                                  provenance: "Searched every granted folder, subfolders included.",
                                  run: { _ in "" })
        }
        return ProposedAction(
            kind: .answer,
            title: files.count == 1 ? "Found it" : "\(files.count) matches",
            groups: FilePages.groups(files),
            provenance: "Searched \(roots.roots.count) granted folder\(roots.roots.count == 1 ? "" : "s"), subfolders included.",
            confirmLabel: "Reveal in Finder",
            run: { picked in
                guard let picked else { return "Pick one first." }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: picked)])
                return "Shown in Finder."
            })
    }
}
