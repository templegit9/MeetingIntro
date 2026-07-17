import Foundation

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

    func plan(_ job: OrganizeJob) async -> [FileProposal] {
        lastError = nil
        guard let config, config.llmReady else { lastError = "Set a model + API key first."; return [] }
        guard let dir = resolveSource(job) else { lastError = "Can't access that folder — re-pick it."; return [] }
        defer { dir.stopAccessingSecurityScopedResource() }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        let files = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        guard !files.isEmpty else { lastError = "No files to organize in this folder."; return [] }

        let previews = files.map { FilePreviewExtractor.extract($0) }
        isPlanning = true
        defer { isPlanning = false }
        do {
            let raw = try await callModel(previews: previews, rename: job.renameEnabled)
            let proposals = parse(raw, files: files)
            if proposals.isEmpty { lastError = "The model returned no usable proposals." }
            diagnosticLog?.info(.assistant, "Planned \"\(job.name)\": \(files.count) files → \(proposals.count) proposals")
            return proposals
        } catch {
            lastError = describe(error)
            diagnosticLog?.error(.assistant, "Plan failed for \"\(job.name)\": \(lastError ?? "")")
            return []
        }
    }

    private func callModel(previews: [FilePreview], rename: Bool) async throws -> String {
        guard let config else { throw NSError(domain: "assistant", code: 0) }
        let system = """
        You organize files into subfolders by type and content. You get a numbered list of files with metadata and short content previews. For EACH file propose a destination subfolder and (if renaming is on) a cleaner filename.
        Reply with ONLY a JSON array, no prose, no code fences:
        [{"index": int, "folder": string, "newName": string or null, "observedReason": string, "renameReason": string or null}]
        Rules:
        - "folder": a short Title Case destination subfolder grouping similar files (e.g. "Invoices", "Screenshots", "Contracts", "Images", "Receipts"). Reuse the same folder name for similar files.
        - "newName": \(rename ? "a clean descriptive filename that KEEPS the original extension, or null to keep the current name. Prefer \"YYYY-MM-DD Description.ext\" when a date is evident." : "ALWAYS null (renaming is off).")
        - "observedReason": ONE short sentence on why that folder, grounded ONLY in the content/metadata you were shown. Never invent content you didn't see.
        - "renameReason": ONE short sentence, or null.
        Return exactly one object per input index.
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
            let folder = (obj["folder"] as? String) ?? ""
            let newNameRaw = (obj["newName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let proposedName = newNameRaw.map { ensureExtension($0, like: url) } ?? url.lastPathComponent
            out.append(FileProposal(
                originalURL: url, proposedFolder: folder, proposedName: proposedName,
                observedReason: (obj["observedReason"] as? String) ?? "",
                renameReason: (obj["renameReason"] as? String) ?? ""))
        }
        return out
    }

    // MARK: - Apply / Undo

    func apply(_ proposals: [FileProposal], job: OrganizeJob) -> UndoBatch? {
        guard let dir = resolveSource(job) else { lastError = "Can't access that folder — re-pick it."; return nil }
        defer { dir.stopAccessingSecurityScopedResource() }

        var moves: [FileMove] = []
        var createdFolders: [String] = []
        for p in proposals where p.include {
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
        guard !moves.isEmpty else { return nil }
        let batch = UndoBatch(jobName: job.name.isEmpty ? "Folder" : job.name, timestamp: Date(), moves: moves, createdFolders: createdFolders)
        config?.recordUndo(batch)
        return batch
    }

    func undo(_ batch: UndoBatch) {
        for m in batch.moves.reversed() {
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: m.to), to: URL(fileURLWithPath: m.from))
        }
        for f in batch.createdFolders {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: f), contents.isEmpty {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: f))
            }
        }
        config?.removeUndo(batch.id)
        diagnosticLog?.info(.assistant, "Undid organize batch \"\(batch.jobName)\" (\(batch.moves.count) files)")
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
}
