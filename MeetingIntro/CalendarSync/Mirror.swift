import Combine
import Foundation

/// One configured calendar mirror: source calendar(s) → a destination calendar,
/// one-way and continuous. The destination is a read-only reflection.
struct Mirror: Codable, Identifiable, Equatable {
    enum DetailMode: String, Codable, CaseIterable {
        case full   // copy title / location / notes
        case busy   // opaque "Busy" blocks — no details leaked

        var displayName: String {
            switch self {
            case .full: return "Full details"
            case .busy: return "Busy only"
            }
        }
    }

    var id: UUID
    var name: String
    var sourceCalendarIDs: [String]
    var destinationCalendarID: String
    /// True when MeetingIntro created the destination (so teardown can offer to
    /// delete the whole calendar, not just its events).
    var isDedicatedCalendar: Bool
    var detailMode: DetailMode
    var enabled: Bool
    /// When the user disables/deletes this mirror, also remove the copies it made.
    var deleteCopiesOnDisable: Bool
    var lastSync: Date?
    var lastError: String?
    /// Tripped by the delete circuit-breaker — held until the user re-enables.
    var paused: Bool
    /// One-shot consent to a large deletion, set when the user does something that makes
    /// mass removal the *correct* outcome: changing which calendars are mirrored, or
    /// clicking Re-enable on a mirror the breaker already paused (the message tells them
    /// the count first). Consumed by the next reconcile.
    ///
    /// Without it the breaker was a trap: re-saving or re-enabling cleared `paused`, the
    /// next reconcile found the same orphans and paused again, so the mirror could never
    /// converge and every escape route led back into it. **Optional on purpose** — a
    /// non-optional addition would fail to decode mirrors persisted before this release,
    /// silently losing the user's configuration.
    var approveLargeChangeOnce: Bool?

    init(
        id: UUID = UUID(),
        name: String,
        sourceCalendarIDs: [String],
        destinationCalendarID: String,
        isDedicatedCalendar: Bool,
        detailMode: DetailMode = .busy,
        enabled: Bool = true,
        deleteCopiesOnDisable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sourceCalendarIDs = sourceCalendarIDs
        self.destinationCalendarID = destinationCalendarID
        self.isDedicatedCalendar = isDedicatedCalendar
        self.detailMode = detailMode
        self.enabled = enabled
        self.deleteCopiesOnDisable = deleteCopiesOnDisable
        self.lastSync = nil
        self.lastError = nil
        self.paused = false
        self.approveLargeChangeOnce = nil
    }
}

/// Outcome of writing one mirror event — lets the engine skip an empty commit
/// (and the `EKEventStoreChanged` storm it triggers) when nothing actually changed.
enum MirrorWriteResult {
    case created
    case updated
    case unchanged
}

/// Encodes the source linkage into a mirror event's `url` so the destination
/// calendar IS the sync state — no external mapping DB to drift.
/// Form: `meetingintro-mirror://<mirrorUUID>/<base64url(sourceEventID)>`.
enum MirrorMarker {
    static let scheme = "meetingintro-mirror"

    static func encode(mirrorID: UUID, sourceID: String) -> URL? {
        let encoded = Data(sourceID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://\(mirrorID.uuidString)/\(encoded)")
    }

    /// Returns (mirrorID, sourceID) if the url is one of ours.
    static func decode(_ url: URL?) -> (mirrorID: UUID, sourceID: String)? {
        guard let url, url.scheme == scheme,
              let host = url.host,
              let mirrorID = UUID(uuidString: host) else { return nil }
        let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var b64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let sourceID = String(data: data, encoding: .utf8) else { return nil }
        return (mirrorID, sourceID)
    }

    /// Cheap check: is this url one of our mirror markers at all?
    static func isMirror(_ url: URL?) -> Bool {
        url?.scheme == scheme
    }
}

/// Persists the user's mirror configurations and exposes them for the engine + UI.
@MainActor
final class MirrorConfigManager: ObservableObject {
    @Published var mirrors: [Mirror] {
        didSet { save() }
    }

    private static let key = "calendarMirrors"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Mirror].self, from: data) {
            self.mirrors = decoded
        } else {
            self.mirrors = []
        }
    }

    func upsert(_ mirror: Mirror) {
        if let idx = mirrors.firstIndex(where: { $0.id == mirror.id }) {
            mirrors[idx] = mirror
        } else {
            mirrors.append(mirror)
        }
    }

    func remove(_ id: UUID) {
        mirrors.removeAll { $0.id == id }
    }

    /// Mutate a mirror in place by id (engine uses this to stamp lastSync/paused).
    func update(_ id: UUID, _ mutate: (inout Mirror) -> Void) {
        guard let idx = mirrors.firstIndex(where: { $0.id == id }) else { return }
        var m = mirrors[idx]
        mutate(&m)
        mirrors[idx] = m
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mirrors) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
