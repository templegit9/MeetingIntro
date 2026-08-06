import AppKit
import SwiftUI

/// Manages the floating countdown overlay window.
/// Uses an NSPanel for proper always-on-top behavior.
@MainActor
final class OverlayWindowController: ObservableObject {

    @Published var isShowing: Bool = false

    /// Largest share of the screen's visible frame the countdown overlay may occupy.
    /// A reminder should read as a card on top of your work, not take the screen over —
    /// the pre-v2.15.4 fixed 560/720pt panel did exactly that on a 1080p display.
    private static let maxScreenFraction: CGFloat = 0.72

    /// Below this much vertical room (points, visible frame) the overlay switches to the
    /// compact layout outright — not just when the roomy one literally wouldn't fit.
    /// A 1080p display has ~1000pt of usable height, where the roomy panel reads as
    /// "it fills my screen" (the reported complaint) even though it technically fits.
    private static let compactBelowScreenHeight: CGFloat = 1100

    /// Floor for the content-derived panel height, so a bare meeting (no link, no
    /// details) still reads as a deliberate card rather than a thin strip.
    private static let minPanelHeight: CGFloat = 360

    private var overlayWindow: NSPanel?
    /// Separate slot for the cancellation notice so it never collides with an
    /// active countdown overlay — both can be on screen at once.
    private var cancellationWindow: NSPanel?
    /// Separate slot for the auto-join heads-up (gentle pre-start overlay).
    private var autoJoinImminentWindow: NSPanel?
    private var autoJoinImminentID: String?
    /// Separate slot for a task deadline reminder (Issue #19).
    private var taskDeadlineWindow: NSPanel?
    private var calendarManager: CalendarManager?
    private var audioManager: AudioManager?
    /// Injected so the task overlay's "Mark done" can complete the task.
    weak var taskManager: TaskManager?
    /// Injected so the task overlay's "Snooze" can re-arm the reminder.
    weak var taskReminderCoordinator: TaskReminderCoordinator?

    /// Diagnostic log — injected in AppLifecycleManager.observe.
    var diagnosticLog: DiagnosticLog?

    func configure(calendarManager: CalendarManager, audioManager: AudioManager) {
        self.calendarManager = calendarManager
        self.audioManager = audioManager
    }

    /// Show the countdown overlay for the given meeting.
    func show(for meeting: MeetingEvent) {
        guard overlayWindow == nil else {
            diagnosticLog?.debug(.overlay, "Countdown overlay show skipped (already showing) — \(meeting.title)")
            return
        }
        diagnosticLog?.info(.overlay, "Showing countdown overlay — \(meeting.title)")

        // Panel size is derived from the content, then clamped to the screen. The old
        // fixed 560/720pt panel was wrong in both directions: it swallowed a 1080p (or
        // scaled) display, yet on a busy meeting the lower buttons still didn't fit
        // inside it. Now: pick the compact layout on short screens (or by preference),
        // ask the view how tall its content actually is, and cap that at
        // `maxScreenFraction` of the visible frame. The view gets the same `compact`
        // flag, so its metrics and the panel always agree.
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let maxHeight = (visibleFrame?.height ?? 900) * Self.maxScreenFraction
        let maxWidth = (visibleFrame?.width ?? 1200) * Self.maxScreenFraction

        let forcedCompact = UserDefaults.standard.object(forKey: "overlayCompactLayout") as? Bool ?? false
        let compact = forcedCompact || (visibleFrame.map { $0.height < Self.compactBelowScreenHeight } ?? false)
        let panelWidth = min(compact ? 380 : 420, maxWidth)

        let overlayView = CountdownOverlayView(
            meeting: meeting,
            compact: compact,
            onDismiss: { [weak self] in self?.dismiss() },
            onArmAutoJoin: { [weak self] in
                // Arm the auto-join, then close the overlay. The link opens
                // automatically at start time (CalendarManager.evaluateAutoJoin).
                self?.calendarManager?.armAutoJoin(meeting.id)
                self?.dismiss()
            },
            onDismissFutureReminders: { [weak self] in
                self?.calendarManager?.dismissReminders(meeting.id)
                self?.dismiss()
            }
        )

        // Fit the panel to the content (never taller than the screen allows). The view
        // keeps a ScrollView safety net for the rare case the clamp bites.
        let panelHeight = min(max(overlayView.contentFittingHeight(width: panelWidth), Self.minPanelHeight), maxHeight)

        let hostingView = NSHostingView(rootView: overlayView)

        // Create a floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // The overlay is designed dark (white text on dark blur). Without forcing
        // dark appearance, the .hudWindow material renders LIGHT in light mode and
        // the white text washes out to invisible.
        panel.appearance = NSAppearance(named: .darkAqua)

        // Center on screen
        if let screenFrame = visibleFrame {
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.midY - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        diagnosticLog?.debug(.overlay, "Overlay panel \(Int(panelWidth))×\(Int(panelHeight))\(compact ? " (compact)" : "") — screen \(visibleFrame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "unknown")")

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        overlayWindow = panel
        isShowing = true

        // Start the music
        audioManager?.play()
    }

    /// Dismiss the overlay and stop music.
    func dismiss() {
        diagnosticLog?.info(.overlay, "Countdown overlay dismissed")
        if let window = overlayWindow {
            // Order out + drop the hosting view so its SwiftUI `onDisappear` fires and
            // invalidates the countdown Timer (a leaked/stalled timer was part of the
            // "overlay won't close or respond" report), then close.
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        overlayWindow = nil
        isShowing = false

        audioManager?.fadeOut(duration: 1.5)
        calendarManager?.dismissCountdown()
    }

    // MARK: - Cancellation notice

    /// Where the cancellation notice appears. Persisted via UserDefaults
    /// (`cancellationOverlayPosition`); default is the top-right toast.
    enum CancellationOverlayPosition: String, CaseIterable {
        case topRight
        case center

        var displayName: String {
            switch self {
            case .topRight: return "Top right (toast)"
            case .center: return "Center (like meeting overlay)"
            }
        }
    }

    /// IDs currently rendered in the cancellation notice — makes
    /// `showCancellationCenter` idempotent so the state-driven subscriber can
    /// call it on every publish without rebuild flicker.
    private var currentNoticeIDs: Set<String> = []

    /// Show (or update) the persistent cancellation notice. Renders the pending
    /// cancellations as a dismissable list — NO auto-dismiss; the panel lives
    /// until every item is acknowledged. The state-driven subscriber in
    /// AppLifecycleManager calls `dismissCancellationNotice` when the pending
    /// list empties or a smart-context hold (in a call / screen sharing) kicks in.
    func showCancellationCenter(_ items: [MeetingEvent], onDismissItem: @escaping (String) -> Void) {
        guard !items.isEmpty else { dismissCancellationNotice(); return }
        let ids = Set(items.map(\.id))
        if ids == currentNoticeIDs, cancellationWindow != nil { return }

        cancellationWindow?.close()
        cancellationWindow = nil

        let view = CancellationOverlayView(items: items, onDismissItem: onDismissItem)
        let hostingView = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 400
        // Header + footer ≈ 110pt; ~58pt per row; cap so long lists scroll.
        let panelHeight: CGFloat = min(110 + CGFloat(items.count) * 58, 420)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = true
        // Dark-designed view (white text on dark blur) — force dark appearance so
        // light mode doesn't render the .hudWindow material light and wash it out.
        panel.appearance = NSAppearance(named: .darkAqua)

        // Position per user setting. Top-right toast keeps it clear of a
        // simultaneously-visible countdown overlay; center matches the meeting
        // overlay's placement for users who want cancellations equally prominent.
        let position = CancellationOverlayPosition(
            rawValue: UserDefaults.standard.string(forKey: "cancellationOverlayPosition") ?? ""
        ) ?? .topRight
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin: NSPoint
            switch position {
            case .topRight:
                origin = NSPoint(x: frame.maxX - panelWidth - 20, y: frame.maxY - panelHeight - 20)
            case .center:
                origin = NSPoint(x: frame.midX - panelWidth / 2, y: frame.midY - panelHeight / 2)
            }
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        cancellationWindow = panel
        currentNoticeIDs = ids
    }

    /// Settings "Test Cancellation Notice" hook — previews the panel with one
    /// sample item whose Dismiss simply closes the preview.
    func showCancellation(for meeting: MeetingEvent) {
        showCancellationCenter([meeting]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissCancellationNotice() }
        }
    }

    func dismissCancellationNotice() {
        cancellationWindow?.close()
        cancellationWindow = nil
        currentNoticeIDs = []
    }

    // MARK: - Auto-join heads-up (gentle pre-start overlay)

    /// Show (or update) the small heads-up before an armed meeting auto-joins.
    /// Idempotent on the meeting id so the per-second driver can call it freely.
    func showAutoJoinImminent(_ meeting: MeetingEvent, onCancel: @escaping () -> Void, onJoinNow: @escaping () -> Void) {
        if autoJoinImminentID == meeting.id, autoJoinImminentWindow != nil { return }
        autoJoinImminentWindow?.close()

        let view = AutoJoinImminentView(meeting: meeting, onCancel: onCancel, onJoinNow: onJoinNow)
        let hostingView = NSHostingView(rootView: view)
        let width: CGFloat = 420, height: CGFloat = 76
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = true
        // Dark-designed (white text on dark) — force dark so light mode doesn't wash it out.
        panel.appearance = NSAppearance(named: .darkAqua)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - width - 20, y: frame.maxY - height - 20))
        }
        panel.orderFrontRegardless()
        autoJoinImminentWindow = panel
        autoJoinImminentID = meeting.id
    }

    func dismissAutoJoinImminent() {
        autoJoinImminentWindow?.close()
        autoJoinImminentWindow = nil
        autoJoinImminentID = nil
    }

    /// Show a task deadline overlay (a small corner card with Mark done / Dismiss).
    func showTaskDeadline(for task: TaskItem) {
        taskDeadlineWindow?.close()
        let view = TaskDeadlineOverlayView(
            task: task,
            onDone: { [weak self] in
                self?.taskManager?.complete(task.id)
                self?.dismissTaskDeadline()
            },
            onSnooze: { [weak self] in
                self?.taskReminderCoordinator?.snooze(taskID: task.id, minutes: 10)
            },
            onDismiss: { [weak self] in self?.dismissTaskDeadline() }
        )
        let hostingView = NSHostingView(rootView: view)
        let width: CGFloat = 380, height: CGFloat = 120
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - width - 20, y: frame.maxY - height - 20))
        }
        panel.orderFrontRegardless()
        taskDeadlineWindow = panel
        diagnosticLog?.info(.overlay, "Showing task deadline overlay — \(task.title)")
    }

    func dismissTaskDeadline() {
        taskDeadlineWindow?.close()
        taskDeadlineWindow = nil
    }
}
