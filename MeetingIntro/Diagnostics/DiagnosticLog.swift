import Combine
import Foundation

/// App-wide diagnostic log for triaging "why didn't that fire?" issues.
///
/// Two sinks: an in-memory ring buffer (the @Published source the Diagnostics
/// view renders) and a daily rotating file in Application Support (for sharing /
/// after-the-fact inspection). File writes go through a serial queue off the main
/// actor so logging never blocks UI. Injected explicitly into the managers that
/// log — no global `.shared`, matching the project's no-environment-singletons rule.
@MainActor
final class DiagnosticLog: ObservableObject {

    enum Level: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }
    }

    enum Category: String, CaseIterable {
        case lifecycle, notification, reminder, cancellation, overlay
        case recording, transcription, notes, quickAdd, calendar, handoff
    }

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: Category
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    private static let ringCapacity = 2000
    private static let retentionDays = 7
    private let fileQueue = DispatchQueue(label: "com.oluyinka.MeetingIntro.diagnostics", qos: .utility)
    /// Day-string of the last prune, so a never-quit menu-bar instance still
    /// prunes once per calendar day (prune-on-launch alone wouldn't fire).
    private var lastPruneDay = ""
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        fileQueue.async { Self.pruneOldFiles() }
    }

    // MARK: - Logging

    func log(_ level: Level, _ category: Category, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > Self.ringCapacity {
            entries.removeFirst(entries.count - Self.ringCapacity)
        }
        let line = "\(isoFormatter.string(from: entry.timestamp)) [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
        fileQueue.async { Self.append(line) }

        // Prune once per calendar day even if the app never restarts.
        let today = Self.dayString(entry.timestamp)
        if today != lastPruneDay {
            lastPruneDay = today
            fileQueue.async { Self.pruneOldFiles() }
        }
    }

    func debug(_ category: Category, _ message: String) { log(.debug, category, message) }
    func info(_ category: Category, _ message: String) { log(.info, category, message) }
    func warn(_ category: Category, _ message: String) { log(.warning, category, message) }
    func error(_ category: Category, _ message: String) { log(.error, category, message) }

    // MARK: - View support

    /// Full in-memory log as text, newest last, for the Copy button.
    func exportText(filter: (Entry) -> Bool = { _ in true }) -> String {
        entries.filter(filter).map {
            "\(isoFormatter.string(from: $0.timestamp)) [\($0.level.rawValue)] [\($0.category.rawValue)] \($0.message)"
        }.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        fileQueue.async {
            if let url = Self.todayFileURL() { try? "".write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    static var logDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingIntro/Diagnostics", isDirectory: true)
    }

    // MARK: - File plumbing (runs on fileQueue)

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func todayFileURL() -> URL? {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        return logDirectory.appendingPathComponent("meetingintro-\(dayString(Date())).log")
    }

    private static func append(_ line: String) {
        guard let url = todayFileURL(), let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func pruneOldFiles() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in items where url.pathExtension == "log" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
