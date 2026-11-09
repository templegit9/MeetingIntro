import Foundation

/// Local text receipts only. Executable proposals and undo closures never enter the archive.
@MainActor
final class MarginHistory: ObservableObject {
    enum RibbonColor: String, Codable, CaseIterable, Identifiable {
        case red, gold, green, purple, orange, teal, blue, pink, lime, cyan, brown, slate
        var id: String { rawValue }
    }
    struct Bookmark: Codable {
        var color: RibbonColor
        var title: String
        var order: Int
    }
    struct Entry: Codable, Identifiable {
        let id: UUID
        let title: String
        let updated: Date
        let turns: [SavedTurn]
        var imagePageID: UUID? = nil
        var bookmark: Bookmark? = nil
        var displayTitle: String { bookmark?.title ?? title }
        var performed: Bool { turns.contains { $0.performed == true } }
        var summary: String { turns.last(where: { !$0.user })?.summary ?? "Saved page" }
    }
    struct SavedTurn: Codable, Equatable {
        let user: Bool
        let text: String
        var performed: Bool? = nil
        var summary: String? = nil
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var problem: String?
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingIntro/Margin/history.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: self.url))
            }
        } catch { problem = "Saved history could not be read: \(error.localizedDescription)" }
    }

    func save(id: UUID, turns: [AssistantTurn], days: Int) {
        guard !turns.isEmpty else { return }
        // Never overwrite an unreadable archive with an empty one.
        guard problem == nil else { return }
        var entry = Entry(id: id, title: String((turns.first(where: { $0.role == .user })?.text ?? "Conversation").prefix(100)),
                          updated: Date(), turns: turns.suffix(100).map {
                            SavedTurn(user: $0.role == .user, text: $0.contextText, performed: $0.performed,
                                      summary: $0.outcome ?? ($0.action?.kind == .change ? "Awaiting confirmation" : "Answer only"))
                          })
        entry.imagePageID = entries.first(where: { $0.id == id })?.imagePageID
        entry.bookmark = entries.first(where: { $0.id == id })?.bookmark
        if entries.first(where: { $0.id == id })?.turns == entry.turns { return }
        entries.removeAll { $0.id == id }
        entries.insert(entry, at: 0)
        prune(days: days)
        write()
    }

    func prune(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400)
        let retained = entries.filter { $0.bookmark != nil } + Array(entries.filter { $0.bookmark == nil && $0.updated >= cutoff }.prefix(100))
        guard retained.count != entries.count else { return }
        entries = retained
        write()
    }

    var bookmarks: [Entry] {
        entries.filter { $0.bookmark != nil }.sorted { ($0.bookmark?.order ?? 0) < ($1.bookmark?.order ?? 0) }
    }

    func mark(_ id: UUID, color: RibbonColor, title: String? = nil) {
        guard problem == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[index].bookmark
        let proposed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].bookmark = Bookmark(color: color,
            title: String((proposed?.isEmpty == false ? proposed! : old?.title ?? entries[index].title).prefix(160)),
            order: old?.order ?? ((bookmarks.compactMap { $0.bookmark?.order }.max() ?? -1) + 1))
        write()
    }

    func unmark(_ id: UUID) {
        guard problem == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].bookmark = nil
        write()
    }

    func moveBookmark(_ id: UUID, before target: UUID) {
        guard problem == nil, id != target else { return }
        var ids = bookmarks.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target) else { return }
        ids.insert(id, at: to)
        for (order, id) in ids.enumerated() {
            if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].bookmark?.order = order }
        }
        write()
    }

    private var imageDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("image-pages", isDirectory: true) }

    func saveImagePage(id: UUID, title: String, payload: Data, color: RibbonColor) throws {
        guard problem == nil else { throw CocoaError(.fileWriteUnknown) }
        guard payload.count <= 180_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectory.path)
        let ownedFiles = (try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let used = ownedFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard used + payload.count <= 600_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        // A new immutable payload first; the archive reference is committed afterwards.
        let payloadID = UUID()
        let target = imageDirectory.appendingPathComponent(payloadID.uuidString + ".json")
        try payload.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let previous = entries
        let bookmark = entries.first(where: { $0.id == id })?.bookmark
            ?? Bookmark(color: color, title: title, order: (bookmarks.compactMap { $0.bookmark?.order }.max() ?? -1) + 1)
        var entry = Entry(id: id, title: title, updated: Date(), turns: [
            SavedTurn(user: true, text: title),
            SavedTurn(user: false, text: "Saved image page. Open the page to inspect its source and any answer. No file or calendar action was performed.", performed: false, summary: "Image page")])
        entry.imagePageID = payloadID
        entry.bookmark = Bookmark(color: color, title: bookmark.title, order: bookmark.order)
        entries.removeAll { $0.id == id }; entries.insert(entry, at: 0)
        write()
        if problem != nil { entries = previous; try? FileManager.default.removeItem(at: target); throw CocoaError(.fileWriteUnknown) }
    }

    func forgetImagePage(_ id: UUID) {
        guard problem == nil, entries.contains(where: { $0.id == id && $0.imagePageID != nil }) else { return }
        let previous = entries
        entries.removeAll { $0.id == id }
        write()
        if problem != nil { entries = previous }
    }

    func imagePayload(for entry: Entry) throws -> Data? {
        guard let id = entry.imagePageID else { return nil }
        let file = imageDirectory.appendingPathComponent(id.uuidString + ".json")
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 180_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: file)
    }

    /// Only files owned by this archive, identified by UUID, are eligible for cleanup.
    private func removeUnreferencedImages() {
        let retained = Set(entries.compactMap(\.imagePageID).map { $0.uuidString + ".json" })
        guard let files = try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !retained.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func clear() {
        entries = []
        problem = nil
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            removeUnreferencedImages()
            problem = nil
        } catch { problem = "History could not be saved: \(error.localizedDescription)" }
    }
}
