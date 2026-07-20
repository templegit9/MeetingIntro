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
    /// When an automated run fires (schedule/watch): true = apply immediately (with undo),
    /// false = notify + open the preview to review first. Manual "Organize now" always previews.
    var autoApply: Bool = false
    // MARK: Phase 2 automation triggers (v2.13.0)
    /// Run on a recurring interval.
    var scheduleEnabled: Bool = false
    /// How the schedule fires (v2.14.0). Optional so older persisted jobs decode.
    var scheduleKind: ScheduleKind? = nil
    /// Interval between scheduled runs, in hours (`.interval`).
    var scheduleIntervalHours: Int = 24
    /// Time of day for `.dailyAt` scheduling.
    var scheduleHour: Int? = nil
    var scheduleMinute: Int? = nil
    /// React when new files land in the folder (debounced).
    var watchEnabled: Bool = false
    /// Last time an automated run fired (for scheduling cadence). Persisted.
    var lastRunAt: Date? = nil
}

/// How a scheduled job fires.
enum ScheduleKind: String, Codable, CaseIterable { case interval, dailyAt }

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

/// Whether a proposal moves the file into a folder or sends it to the Trash.
enum ProposalAction: Equatable { case move, trash }

/// How the file to organize was scoped — top-level only, or recursively flattened.
enum OrganizeMode { case organize, reorganize }

/// One proposed action from the model or a rule — where a file should go (or Trash) and
/// (optionally) its new name, each with a human-readable reason surfaced in the preview.
struct FileProposal: Identifiable {
    let id = UUID()
    let originalURL: URL
    var proposedFolder: String
    /// Includes the extension. Equals the original name when no rename is proposed.
    var proposedName: String
    var observedReason: String
    var renameReason: String
    var include: Bool = true
    /// Move into `proposedFolder`, or send to Trash (from a Trash rule).
    var action: ProposalAction = .move
    /// Name of the rule that produced this proposal, if any (vs. the model).
    var ruleName: String? = nil

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
    /// Files sent to the Trash (`from` = original, `to` = URL in Trash) — undo restores.
    /// Optional so older persisted batches still decode.
    var trashed: [FileMove]? = nil
    /// Empty folders removed during a Re-organize (recreated on undo).
    var removedFolders: [String]? = nil

    var totalActions: Int { moves.count + (trashed?.count ?? 0) }
}

// MARK: - Rules (deterministic, run before the AI)

/// How a rule matches a file. `.ai` is a natural-language description evaluated by the
/// model (not matched deterministically here).
struct RuleMatch: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case ext, nameContains, regex, ai }
    var kind: Kind = .ext
    var pattern: String = ""
}

/// What a matching rule does with the file.
enum RuleAction: Codable, Equatable {
    case folder(String)   // file into this subfolder
    case skip             // leave untouched (excluded from the run)
    case trash            // move to the macOS Trash
}

/// A user-defined organize rule. Evaluated before the model — matching files get a
/// deterministic proposal (and never hit the LLM), for predictability + lower cost.
struct OrganizeRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var enabled: Bool = true
    var match: RuleMatch = RuleMatch()
    var action: RuleAction = .folder("")

    /// True if this rule *deterministically* matches the file. `.ai` rules always return
    /// false here — they're evaluated by the model (injected as prompt directives).
    func matches(_ preview: FilePreview) -> Bool {
        guard enabled else { return false }
        let pat = match.pattern.trimmingCharacters(in: .whitespaces)
        guard !pat.isEmpty else { return false }
        switch match.kind {
        case .ext:
            return preview.ext.caseInsensitiveCompare(pat.hasPrefix(".") ? String(pat.dropFirst()) : pat) == .orderedSame
        case .nameContains:
            return preview.name.range(of: pat, options: .caseInsensitive) != nil
        case .regex:
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: preview.name, range: NSRange(preview.name.startIndex..., in: preview.name)) != nil
        case .ai:
            return false
        }
    }

    /// Whether this is a natural-language (model-evaluated) rule.
    var isAI: Bool { match.kind == .ai }

    /// The action phrased as a directive for the model prompt (AI rules only).
    var aiDirective: String {
        let a: String
        switch action {
        case .folder(let f): a = "file it into the folder \"\(f)\""
        case .skip: a = "skip it (do not move it)"
        case .trash: a = "move it to the Trash"
        }
        return "If a file is \(match.pattern.trimmingCharacters(in: .whitespaces)), \(a)."
    }

    /// One-line summary for the rules list.
    var summary: String {
        let m: String
        switch match.kind {
        case .ext: m = "*.\(match.pattern)"
        case .nameContains: m = "name contains “\(match.pattern)”"
        case .regex: m = "/\(match.pattern)/"
        case .ai: m = "AI: “\(match.pattern)”"
        }
        let a: String
        switch action {
        case .folder(let f): a = "→ \(f.isEmpty ? "?" : f)"
        case .skip: a = "→ skip"
        case .trash: a = "→ Trash"
        }
        return "\(m) \(a)"
    }
}
