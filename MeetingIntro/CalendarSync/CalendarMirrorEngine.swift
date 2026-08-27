import Combine
import Foundation

/// One-way continuous reconciler: for each enabled mirror, makes the destination
/// calendar reflect its source calendars (create/update/delete copies).
///
/// Safety model (see plan): only events carrying our marker are ever touched; a
/// delete circuit-breaker pauses a mirror rather than mass-deleting on a source
/// hiccup; every action is logged to DiagnosticLog as an audit trail.
@MainActor
final class CalendarMirrorEngine: ObservableObject {

    /// Mirror events to sync forward.
    static let syncWindow: TimeInterval = 30 * 86400   // 30 days

    /// Circuit-breaker thresholds: a single reconcile that would delete more than
    /// this many copies, OR wipe more than this fraction of existing copies, pauses
    /// the mirror instead of executing — guards against a source transiently
    /// returning zero events (account hiccup) nuking everything.
    static let deleteCountCeiling = 50
    static let deleteFractionCeiling = 0.9

    private var config: MirrorConfigManager?
    private weak var calendarManager: CalendarManager?
    var diagnosticLog: DiagnosticLog?

    private var isReconciling = false

    init() {}

    /// Late-wire (same pattern as the recording/handoff coordinators) — called
    /// from AppLifecycleManager.observe once the @StateObjects exist. Hooks the
    /// calendar poll so reconciliation rides the existing 30s cycle.
    func attach(config: MirrorConfigManager, calendarManager: CalendarManager) {
        self.config = config
        self.calendarManager = calendarManager
        calendarManager.onPollComplete = { [weak self] in self?.reconcileAll() }
    }

    /// Reconcile every enabled, non-paused mirror. Re-entrancy guarded so an
    /// EKEventStoreChanged storm during our own writes doesn't recurse.
    func reconcileAll() {
        guard !isReconciling else { return }
        guard let config, let provider = calendarManager?.eventKitProvider else { return }
        let mirrors = config.mirrors.filter { $0.enabled && !$0.paused }
        guard !mirrors.isEmpty else { return }

        isReconciling = true
        defer { isReconciling = false }

        for mirror in mirrors {
            reconcile(mirror, provider: provider)
        }
    }

    /// Remove every copy a mirror created (used on disable/delete with
    /// deleteCopiesOnDisable). Best-effort; logs the count.
    func tearDown(_ mirror: Mirror) {
        guard let provider = calendarManager?.eventKitProvider else { return }
        let existing = provider.existingMirrorMap(destinationID: mirror.destinationCalendarID, mirrorID: mirror.id)
        guard !existing.isEmpty else { return }
        do {
            try provider.deleteMirrorEvents(Array(existing.values))
            try provider.commitMirrorChanges()
            diagnosticLog?.info(.calendar, "Mirror \"\(mirror.name)\" torn down — removed \(existing.count) copies")
        } catch {
            diagnosticLog?.error(.calendar, "Mirror \"\(mirror.name)\" teardown failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UI helpers

    func destinationName(for mirror: Mirror) -> String? {
        calendarManager?.eventKitProvider.calendarName(mirror.destinationCalendarID)
    }

    func isWritable(_ calendarID: String) -> Bool {
        calendarManager?.eventKitProvider.calendarIsWritable(calendarID) ?? false
    }

    /// Sources a new dedicated calendar can be created on (iCloud / Local).
    func creatableSources() -> [EventKitProvider.CreatableSource] {
        calendarManager?.eventKitProvider.creatableSources() ?? []
    }

    func defaultCreatableSourceID() -> String? {
        calendarManager?.eventKitProvider.defaultCreatableSourceID()
    }

    /// Create a dedicated calendar on the chosen source; returns its id, or sets
    /// `lastCreateError` and returns nil on failure (so the sheet can show why).
    var lastCreateError: String?
    func createDedicatedCalendar(named name: String, sourceID: String?) -> String? {
        guard let provider = calendarManager?.eventKitProvider else { return nil }
        do {
            let id = try provider.createCalendar(named: name, sourceID: sourceID)
            diagnosticLog?.info(.calendar, "Created dedicated mirror calendar \"\(name)\"")
            lastCreateError = nil
            return id
        } catch {
            lastCreateError = error.localizedDescription
            diagnosticLog?.error(.calendar, "Failed to create calendar \"\(name)\": \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Per-mirror reconcile

    private func reconcile(_ mirror: Mirror, provider: EventKitProvider) {
        guard let config else { return }
        // Loop guard: never let the destination be one of the sources.
        let sources = mirror.sourceCalendarIDs.filter { $0 != mirror.destinationCalendarID }
        guard !sources.isEmpty else {
            config.update(mirror.id) { $0.lastError = "No valid source calendars (destination can't be a source)." }
            return
        }

        let desired = provider.mirrorSourceEvents(calendarIDs: sources, window: Self.syncWindow)
        let existing = provider.existingMirrorMap(destinationID: mirror.destinationCalendarID, mirrorID: mirror.id)

        let desiredIDs = Set(desired.map(\.sourceID))
        let orphans = existing.filter { !desiredIDs.contains($0.key) }

        // Circuit-breaker on deletes.
        if !orphans.isEmpty && !existing.isEmpty {
            let fraction = Double(orphans.count) / Double(existing.count)
            if orphans.count > Self.deleteCountCeiling || fraction >= Self.deleteFractionCeiling {
                // The breaker exists for a source calendar that transiently returns
                // nothing. It must NOT block the other case that looks identical from
                // here: the user deliberately changed which calendars are mirrored, where
                // removing the old copies is the whole point. `approveLargeChangeOnce` is
                // that distinction — set by an edit that changes sources/destination, or
                // by Re-enable (whose message states the count before they click).
                if mirror.approveLargeChangeOnce == true {
                    config.update(mirror.id) {
                        $0.approveLargeChangeOnce = false
                        $0.lastError = nil
                    }
                    diagnosticLog?.info(.calendar, "Mirror \"\(mirror.name)\" applying an approved large change — deleting \(orphans.count) of \(existing.count) copies")
                } else {
                    config.update(mirror.id) {
                        $0.paused = true
                        $0.lastError = "Paused for safety: a sync would have deleted \(orphans.count) of \(existing.count) copies. Choose \"Re-enable and sync\" if that's what you intended."
                    }
                    diagnosticLog?.warn(.calendar, "Mirror \"\(mirror.name)\" PAUSED by delete throttle (\(orphans.count)/\(existing.count) copies)")
                    return
                }
            }
        }

        var created = 0, updated = 0, deleted = 0
        do {
            for source in desired {
                switch try provider.writeMirror(source, existing: existing[source.sourceID], destinationID: mirror.destinationCalendarID, mirrorID: mirror.id, mode: mirror.detailMode) {
                case .created: created += 1
                case .updated: updated += 1
                case .unchanged: break
                }
            }
            if !orphans.isEmpty {
                try provider.deleteMirrorEvents(Array(orphans.values))
                deleted = orphans.count
            }
            // Only commit when something actually changed — an empty commit still fires
            // EKEventStoreChanged, which would retrigger reconcile (the churn loop).
            if created + updated + deleted > 0 {
                try provider.commitMirrorChanges()
                diagnosticLog?.info(.calendar, "Mirror \"\(mirror.name)\": +\(created) ~\(updated) -\(deleted) (\(desired.count) source events)")
            }
            config.update(mirror.id) { $0.lastSync = Date(); $0.lastError = nil }
        } catch {
            config.update(mirror.id) { $0.lastError = error.localizedDescription }
            diagnosticLog?.error(.calendar, "Mirror \"\(mirror.name)\" reconcile failed: \(error.localizedDescription)")
        }
    }
}
