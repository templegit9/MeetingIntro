import Foundation
import CryptoKit

/// The Executive Assistant's file-organizer engine (Issue #17, Phase 1 — manual).
/// `plan` asks the model where each file should go (folder + optional rename + reasons);
/// `apply` performs the approved moves (create folder, sanitize, collision-safe move) and
/// records an `UndoBatch`; `undo` reverses it. Never deletes; only ever touches files under
/// the job's picked (security-scoped) folder.
@MainActor
final class FileOrganizer: ObservableObject {
    @Published var isPlanning = false
    @Published var lastError: String?

    private weak var config: AssistantConfig?
    var diagnosticLog: DiagnosticLog?

    func attach(config: AssistantConfig) { self.config = config }

    // MARK: - Folder access

    /// Resolve a job's security-scoped source folder (starts access — caller stops it).
    func resolveSource(_ job: OrganizeJob) -> URL? {
        guard let data = job.sourceBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    // MARK: - Plan

    func plan(_ job: OrganizeJob, mode: OrganizeMode = .organize, ignoreNewerThan: TimeInterval = 0) async -> [FileProposal] {
        lastError = nil
        guard let dir = resolveSource(job) else { lastError = "Can't access that folder — re-pick it."; return [] }
        defer { dir.stopAccessingSecurityScopedResource() }

        let files = gather(in: dir, mode: mode, ignoreNewerThan: ignoreNewerThan)
        guard !files.isEmpty else { lastError = "No files to organize in this folder."; return [] }
        let previews = files.map { FilePreviewExtractor.extract($0) }

        // Existing subfolders → the model files into your structure instead of inventing
        // near-duplicates ("Invoices" vs "Invoice").
        var knownFolders = existingSubfolders(in: dir)

        // Deterministic rules run first (skip drops the file, folder/trash → a proposal); only
        // the *unmatched* files hit the LLM. AI rules + the instructions box guide that pass.
        let allRules = config?.rules.filter { $0.enabled } ?? []
        let rules = allRules.filter { !$0.isAI }
        let aiRules = allRules.filter { $0.isAI }
        let instructions = config?.instructions ?? ""
        var all: [FileProposal] = []
        var unmatched: [(url: URL, preview: FilePreview)] = []
        for (url, p) in zip(files, previews) {
            guard let rule = rules.first(where: { $0.matches(p) }) else { unmatched.append((url, p)); continue }
            let reason = "Rule: \(rule.name.isEmpty ? rule.summary : rule.name)"
            switch rule.action {
            case .skip:
                continue
            case .trash:
                all.append(FileProposal(originalURL: url, proposedFolder: "", proposedName: url.lastPathComponent,
                                        observedReason: reason, renameReason: "", action: .trash, ruleName: rule.name))
            case .folder(let f):
                let folder = f.trimmingCharacters(in: .whitespaces)
                all.append(FileProposal(originalURL: url, proposedFolder: folder, proposedName: url.lastPathComponent,
                                        observedReason: reason, renameReason: "", ruleName: rule.name))
                if !folder.isEmpty { knownFolders.insert(folder) }
            }
        }

        if !unmatched.isEmpty {
            guard let config, config.llmReady else {
                lastError = all.isEmpty ? "Set a model + API key in Settings → AI Models (or add rules)." : nil
                return all
            }
            isPlanning = true
            defer { isPlanning = false }
            // Large folders can exceed the model's context window — batch by a token budget,
            // feeding earlier folder names forward so grouping stays consistent.
            let batches = makeBatches(files: unmatched.map(\.url), previews: unmatched.map(\.preview))
            for (bi, batch) in batches.enumerated() {
                do {
                    let raw = try await callModel(previews: batch.previews, rename: job.renameEnabled, existingFolders: knownFolders,
                                                  instructions: instructions, aiRules: aiRules)
                    let proposals = parse(raw, files: batch.files)
                    all += proposals
                    knownFolders.formUnion(proposals.map { $0.proposedFolder }.filter { !$0.isEmpty })
                    if batches.count > 1 {
                        diagnosticLog?.info(.assistant, "Planned batch \(bi + 1)/\(batches.count) of \"\(job.name)\": \(batch.files.count) → \(proposals.count)")
                    }
                } catch {
                    lastError = describe(error) + (all.isEmpty ? "" : " (showing \(all.count) already analyzed)")
                    diagnosticLog?.error(.assistant, "Plan batch \(bi + 1)/\(batches.count) failed for \"\(job.name)\": \(describe(error))")
                    break
                }
            }
        }

        if all.isEmpty, lastError == nil { lastError = "The model returned no usable proposals." }
        diagnosticLog?.info(.assistant, "Planned \"\(job.name)\" (\(mode == .reorganize ? "reorganize" : "organize")): \(files.count) files → \(all.count) proposals, \(rules.count) rule(s)")
        return all
    }

    /// Incomplete/temp files never to touch (partial downloads, office lock files).
    private static let ignoreExtensions: Set<String> = ["part", "crdownload", "download", "tmp", "partial"]

    /// True if a file should be skipped (temp/partial, or — for watch runs — modified within
    /// `ignoreNewerThan` seconds, i.e. still being written).
    private func skips(_ url: URL, ignoreNewerThan: TimeInterval) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix("~$") { return true }
        if Self.ignoreExtensions.contains(url.pathExtension.lowercased()) { return true }
        if ignoreNewerThan > 0,
           let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(m) < ignoreNewerThan { return true }
        return false
    }

    /// Gather the files to organize. `.organize` = top-level files (+ top-level packages as
    /// units). `.reorganize` = every nested file recursively, plus packages as whole units.
    /// Temp/partial files are always skipped; `ignoreNewerThan` skips still-being-written files.
    private func gather(in dir: URL, mode: OrganizeMode, ignoreNewerThan: TimeInterval = 0) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        switch mode {
        case .organize:
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return entries.filter { url in
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return (v?.isDirectory != true || v?.isPackage == true) && !skips(url, ignoreNewerThan: ignoreNewerThan)
            }
        case .reorganize:
            var out: [URL] = []
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isPackage == true { if !skips(url, ignoreNewerThan: ignoreNewerThan) { out.append(url) }; en.skipDescendants() }
                else if v?.isDirectory != true, !skips(url, ignoreNewerThan: ignoreNewerThan) { out.append(url) }
            }
            return out
        }
    }

    // MARK: - Duplicate finder (offline)

    /// Find byte-identical files (size → SHA-256) and propose Trashing all but one canonical
    /// copy. No LLM. Reuses the trash proposal path (undo restores from Trash).
    func findDuplicates(_ job: OrganizeJob) -> [FileProposal] {
        lastError = nil
        guard let dir = resolveSource(job) else { lastError = "Can't access that folder — re-pick it."; return [] }
        defer { dir.stopAccessingSecurityScopedResource() }
        let files = gather(in: dir, mode: .reorganize)
        guard !files.isEmpty else { lastError = "No files to scan."; return [] }

        var bySize: [Int: [URL]] = [:]
        for u in files {
            let s = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bySize[s, default: []].append(u)
        }
        var proposals: [FileProposal] = []
        for group in bySize.values where group.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in group { if let h = sha256(u) { byHash[h, default: []].append(u) } }
            for dups in byHash.values where dups.count > 1 {
                let sorted = dups.sorted { $0.path.count < $1.path.count }   // keep the shortest path
                for extra in sorted.dropFirst() {
                    proposals.append(FileProposal(originalURL: extra, proposedFolder: "", proposedName: extra.lastPathComponent,
                                                  observedReason: "Duplicate of “\(sorted[0].lastPathComponent)”", renameReason: "",
                                                  action: .trash, ruleName: "Duplicate"))
                }
            }
        }
        if proposals.isEmpty { lastError = "No duplicate files found." }
        diagnosticLog?.info(.assistant, "Duplicate scan \"\(job.name)\": \(files.count) files → \(proposals.count) duplicate(s)")
        return proposals
    }

    private func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Top-level subfolder names (excluding packages/hidden) — fed to the model as the
    /// folders it should reuse.
    private func existingSubfolders(in dir: URL) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        return Set(entries.compactMap { url -> String? in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return (v?.isDirectory == true && v?.isPackage != true) ? url.lastPathComponent : nil
        })
    }

    /// Split aligned (files, previews) into batches under an approximate token budget
    /// (~60K tokens ≈ 240K chars) and a file-count cap, so no single call overruns the
    /// model context. A file whose preview alone exceeds the budget gets its own batch.
    private func makeBatches(files: [URL], previews: [FilePreview]) -> [(files: [URL], previews: [FilePreview])] {
        let maxChars = 240_000
        let maxCount = 80
        var batches: [(files: [URL], previews: [FilePreview])] = []
        var curF: [URL] = []
        var curP: [FilePreview] = []
        var curChars = 0
        for (u, p) in zip(files, previews) {
            let approx = (p.contentPreview?.count ?? 0) + p.name.count + 120
            if !curF.isEmpty && (curChars + approx > maxChars || curF.count >= maxCount) {
                batches.append((curF, curP)); curF = []; curP = []; curChars = 0
            }
            curF.append(u); curP.append(p); curChars += approx
        }
        if !curF.isEmpty { batches.append((curF, curP)) }
        return batches
    }

    private func callModel(previews: [FilePreview], rename: Bool, existingFolders: Set<String>,
                           instructions: String, aiRules: [OrganizeRule]) async throws -> String {
        guard let config else { throw NSError(domain: "assistant", code: 0) }
        let reuse = existingFolders.isEmpty ? "" :
            "\n- These folders ALREADY EXIST in the destination — strongly PREFER filing into one when a file fits it, and match its exact name (don't create near-duplicates like \"Invoice\" next to \"Invoices\"). Only invent a new folder when none fits: \(existingFolders.sorted().joined(separator: ", "))."
        let prefs = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" :
            "\n\nThe user's organizing preferences — FOLLOW THESE closely:\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))"
        let directives = aiRules.isEmpty ? "" :
            "\n\nApply these rules (they override the defaults for matching files):\n" + aiRules.map { "- \($0.aiDirective)" }.joined(separator: "\n")
        let system = """
        You organize files into subfolders by type and content. You get a numbered list of files with metadata and short content previews. For EACH file propose a destination subfolder and (if renaming is on) a cleaner filename.
        Reply with ONLY a JSON array, no prose, no code fences:
        [{"index": int, "folder": string, "newName": string or null, "observedReason": string, "renameReason": string or null, "action": "move"|"trash"|"skip"}]
        Rules:
        - "action": "move" by default. Use "trash" only to discard obvious junk, or "skip" to leave a file untouched — and ONLY when a preference or rule below calls for it.
        - "folder": a short Title Case destination subfolder grouping similar files (e.g. "Invoices", "Screenshots", "Contracts", "Images", "Receipts"). Reuse the same folder name for similar files.\(reuse)
        - "newName": \(rename ? "a clean descriptive filename that KEEPS the original extension, or null to keep the current name. Prefer \"YYYY-MM-DD Description.ext\" when a date is evident." : "ALWAYS null (renaming is off).")
        - "observedReason": ONE short sentence on why that folder (or why trash/skip), grounded ONLY in the content/metadata you were shown. Never invent content you didn't see.
        - "renameReason": ONE short sentence, or null.
        Return exactly one object per input index.\(prefs)\(directives)
        """
        let iso = ISO8601DateFormatter()
        let lines = previews.enumerated().map { i, p -> String in
            var l = "[\(i)] name=\"\(p.name)\" ext=\(p.ext.isEmpty ? "-" : p.ext) size=\(p.sizeBytes)B"
            if let m = p.modified { l += " modified=\(iso.string(from: m))" }
            if let c = p.contentPreview { l += "\n  preview: " + c.replacingOccurrences(of: "\n", with: " ⏎ ") }
            return l
        }
        return try await LLMClient.complete(
            system: system, user: "Files:\n" + lines.joined(separator: "\n"),
            baseURL: config.apiBaseURL, key: config.key, model: config.modelID)
    }

    private func parse(_ raw: String, files: [URL]) -> [FileProposal] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [FileProposal] = []
        for obj in arr {
            guard let idx = obj["index"] as? Int, idx >= 0, idx < files.count else { continue }
            let url = files[idx]
            let action = (obj["action"] as? String)?.lowercased()
            if action == "skip" { continue }   // rule/preference says leave it alone
            let isTrash = action == "trash"
            let folder = isTrash ? "" : ((obj["folder"] as? String) ?? "")
            let newNameRaw = (obj["newName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let proposedName = newNameRaw.map { ensureExtension($0, like: url) } ?? url.lastPathComponent
            out.append(FileProposal(
                originalURL: url, proposedFolder: folder, proposedName: proposedName,
                observedReason: (obj["observedReason"] as? String) ?? "",
                renameReason: (obj["renameReason"] as? String) ?? "",
                action: isTrash ? .trash : .move))
        }
        return out
    }

    // MARK: - Apply / Undo

    func apply(_ proposals: [FileProposal], job: OrganizeJob, mode: OrganizeMode = .organize) -> UndoBatch? {
        guard let dir = resolveSource(job) else { lastError = "Can't access that folder — re-pick it."; return nil }
        defer { dir.stopAccessingSecurityScopedResource() }

        var moves: [FileMove] = []
        var trashed: [FileMove] = []
        var createdFolders: [String] = []
        for p in proposals where p.include {
            if p.action == .trash {
                var resultURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: p.originalURL, resultingItemURL: &resultURL)
                    trashed.append(FileMove(from: p.originalURL.path, to: (resultURL as URL?)?.path ?? ""))
                    diagnosticLog?.info(.assistant, "Trashed \(p.originalURL.lastPathComponent)")
                } catch {
                    diagnosticLog?.warn(.assistant, "Trash failed for \(p.originalURL.lastPathComponent): \(error.localizedDescription)")
                }
                continue
            }
            let folderName = sanitizeComponent(p.proposedFolder)
            let targetDir = folderName.isEmpty ? dir : dir.appendingPathComponent(folderName, isDirectory: true)
            if !folderName.isEmpty, !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                createdFolders.append(targetDir.path)
            }
            let fileName = job.renameEnabled ? sanitizeFileName(p.proposedName, like: p.originalURL) : p.originalURL.lastPathComponent
            let dest = uniqueURL(in: targetDir, fileName: fileName)
            if dest.path == p.originalURL.path { continue }  // no-op
            do {
                try FileManager.default.moveItem(at: p.originalURL, to: dest)
                moves.append(FileMove(from: p.originalURL.path, to: dest.path))
                diagnosticLog?.info(.assistant, "Moved \(p.originalURL.lastPathComponent) → \(folderName)/\(dest.lastPathComponent)")
            } catch {
                diagnosticLog?.warn(.assistant, "Move failed for \(p.originalURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Re-organize flattens the tree — clean up the now-empty original subfolders.
        var removedFolders: [String] = []
        if mode == .reorganize { removedFolders = pruneEmptyDirectories(under: dir) }

        guard !moves.isEmpty || !trashed.isEmpty else { return nil }
        let batch = UndoBatch(jobName: job.name.isEmpty ? "Folder" : job.name, timestamp: Date(),
                              moves: moves, createdFolders: createdFolders,
                              trashed: trashed.isEmpty ? nil : trashed,
                              removedFolders: removedFolders.isEmpty ? nil : removedFolders)
        config?.recordUndo(batch)
        return batch
    }

    func undo(_ batch: UndoBatch) {
        // Recreate folders a Re-organize removed, so files can move back into them.
        for f in batch.removedFolders ?? [] {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: f), withIntermediateDirectories: true)
        }
        for m in batch.moves.reversed() {
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: m.to), to: URL(fileURLWithPath: m.from))
        }
        for m in batch.trashed ?? [] where !m.to.isEmpty {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: m.from).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: m.to), to: URL(fileURLWithPath: m.from))
        }
        for f in batch.createdFolders {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: f),
               contents.filter({ $0 != ".DS_Store" }).isEmpty {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: f))
            }
        }
        config?.removeUndo(batch.id)
        diagnosticLog?.info(.assistant, "Undid organize batch \"\(batch.jobName)\" (\(batch.totalActions) actions)")
    }

    /// Remove empty subdirectories under `root` (deepest-first, never the root, skip
    /// packages). Returns the removed paths for undo. A folder with only `.DS_Store` counts
    /// as empty.
    private func pruneEmptyDirectories(under root: URL) -> [String] {
        var dirs: [URL] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isDirectory == true, v?.isPackage != true { dirs.append(url) }
            }
        }
        dirs.sort { $0.pathComponents.count > $1.pathComponents.count }   // deepest first
        var removed: [String] = []
        for d in dirs {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            if contents.filter({ $0 != ".DS_Store" }).isEmpty {
                try? FileManager.default.removeItem(at: d)
                removed.append(d.path)
            }
        }
        return removed
    }

    // MARK: - Naming helpers

    /// Strip path-hostile chars from a single folder/name component.
    private func sanitizeComponent(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?<>|*\"")
        return raw.components(separatedBy: forbidden).joined()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private func sanitizeFileName(_ raw: String, like original: URL) -> String {
        let cleaned = sanitizeComponent(raw)
        let name = cleaned.isEmpty ? original.lastPathComponent : ensureExtension(cleaned, like: original)
        return String(name.prefix(120))
    }

    /// Ensure the proposed name carries the original extension (models often drop it).
    private func ensureExtension(_ name: String, like original: URL) -> String {
        let ext = original.pathExtension
        guard !ext.isEmpty else { return name }
        return name.lowercased().hasSuffix("." + ext.lowercased()) ? name : name + "." + ext
    }

    private func uniqueURL(in dir: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        func compose(_ n: Int) -> URL {
            let stem = n == 1 ? base : "\(base)-\(n)"
            return dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        var n = 1
        var url = compose(n)
        while FileManager.default.fileExists(atPath: url.path) { n += 1; url = compose(n); if n > 99 { break } }
        return url
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    #if DEBUG
    // MARK: - End-to-end self-test (headless: MEETINGINTRO_SELFTEST=1)
    //
    // Exercises the risky filesystem logic (gather, temp-ignore, packages, recursion,
    // findDuplicates, apply move+trash+collision, reorganize prune, undo) against a temp
    // tree, WITHOUT any LLM and with `config == nil` so it never touches real user data.
    func runSelfTest() -> (pass: Bool, log: String) {
        var failures = 0, checks = 0
        var log = ""
        func check(_ cond: Bool, _ label: String) {
            checks += 1
            if !cond { failures += 1; log += "  ✗ \(label)\n" } else { log += "  ✓ \(label)\n" }
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MISelfTest-\(UUID().uuidString)")
        func write(_ rel: String, _ contents: String) {
            let u = root.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.data(using: .utf8)?.write(to: u)
        }
        defer { try? fm.removeItem(at: root) }

        // Build a known tree.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        write("a.txt", "IDENTICAL")
        write("b.txt", "IDENTICAL")            // byte-dup of a.txt
        write("installer.dmg", "dmg")
        write("chrome.crdownload", "partial")  // temp — must be ignored
        write("Existing/keep.txt", "keep")     // existing subfolder
        write("nested/deep/c.txt", "C")        // for reorganize recursion
        write("fake.rtfd/inner.txt", "pkg")    // package — moved as a unit, not recursed

        // 1) existingSubfolders excludes packages
        let subs = existingSubfolders(in: root)
        check(subs.contains("Existing") && subs.contains("nested"), "existingSubfolders lists real folders")
        check(!subs.contains("fake.rtfd"), "existingSubfolders excludes packages")

        // 2) gather(.organize): top-level files + package unit, temp ignored
        let org = gather(in: root, mode: .organize).map(\.lastPathComponent)
        check(org.contains("a.txt") && org.contains("installer.dmg") && org.contains("fake.rtfd"), "organize gathers top-level + package")
        check(!org.contains("chrome.crdownload"), "organize ignores .crdownload")
        check(!org.contains("inner.txt"), "organize does not recurse into package")

        // 3) gather(.reorganize): recursive files, package as unit, temp ignored
        let reo = gather(in: root, mode: .reorganize).map(\.lastPathComponent)
        check(reo.contains("c.txt") && reo.contains("keep.txt"), "reorganize recurses nested files")
        check(reo.contains("fake.rtfd") && !reo.contains("inner.txt"), "reorganize keeps package as a unit")
        check(!reo.contains("chrome.crdownload"), "reorganize ignores .crdownload")

        // 4) findDuplicates: a.txt/b.txt identical → exactly one trash proposal
        var job = OrganizeJob(); job.name = "SelfTest"
        job.sourceBookmark = try? root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let dups = findDuplicates(job)
        check(dups.count == 1 && dups.first?.action == .trash, "findDuplicates flags one identical copy for Trash")

        // 5) apply move + collision + trash, then undo restores everything
        let aURL = root.appendingPathComponent("a.txt")
        let dmgURL = root.appendingPathComponent("installer.dmg")
        let moveP = FileProposal(originalURL: aURL, proposedFolder: "Docs", proposedName: "a.txt", observedReason: "", renameReason: "")
        let trashP = FileProposal(originalURL: dmgURL, proposedFolder: "", proposedName: "installer.dmg", observedReason: "", renameReason: "", action: .trash)
        guard let batch = apply([moveP, trashP], job: job, mode: .organize) else {
            return (false, log + "  ✗ apply returned nil\n")
        }
        check(fm.fileExists(atPath: root.appendingPathComponent("Docs/a.txt").path), "apply moved a.txt into Docs")
        check(!fm.fileExists(atPath: aURL.path), "original a.txt gone after move")
        check(!fm.fileExists(atPath: dmgURL.path), "installer.dmg trashed")
        check(batch.moves.count == 1 && (batch.trashed?.count ?? 0) == 1, "batch recorded 1 move + 1 trash")
        undo(batch)
        check(fm.fileExists(atPath: aURL.path), "undo restored a.txt to original path")
        check(fm.fileExists(atPath: dmgURL.path), "undo restored trashed installer.dmg")

        // 6) reorganize apply prunes emptied folders, undo recreates them
        let cURL = root.appendingPathComponent("nested/deep/c.txt")
        let reP = FileProposal(originalURL: cURL, proposedFolder: "All", proposedName: "c.txt", observedReason: "", renameReason: "")
        guard let reBatch = apply([reP], job: job, mode: .reorganize) else { return (false, log + "  ✗ reorganize apply nil\n") }
        check(fm.fileExists(atPath: root.appendingPathComponent("All/c.txt").path), "reorganize moved c.txt to All")
        check(!fm.fileExists(atPath: root.appendingPathComponent("nested/deep").path), "reorganize pruned emptied nested/deep")
        check((reBatch.removedFolders?.isEmpty == false), "reorganize recorded removed folders")
        undo(reBatch)
        check(fm.fileExists(atPath: cURL.path), "undo restored c.txt to original nested path")

        let ok = failures == 0
        return (ok, "SELFTEST \(ok ? "PASS" : "FAIL") — \(checks - failures)/\(checks) checks\n" + log)
    }
    #endif
}
