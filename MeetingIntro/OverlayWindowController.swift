import AppKit
import SwiftUI

/// Manages the floating countdown overlay window.
/// Uses an NSPanel for proper always-on-top behavior.
@MainActor
final class OverlayWindowController: ObservableObject {

    @Published var isShowing: Bool = false

    private var overlayWindow: NSPanel?
    /// Separate slot for the cancellation notice so it never collides with an
    /// active countdown overlay — both can be on screen at once.
    private var cancellationWindow: NSPanel?
    private var calendarManager: CalendarManager?
    private var audioManager: AudioManager?

    func configure(calendarManager: CalendarManager, audioManager: AudioManager) {
        self.calendarManager = calendarManager
        self.audioManager = audioManager
    }

    /// Show the countdown overlay for the given meeting.
    func show(for meeting: MeetingEvent) {
        guard overlayWindow == nil else { return }

        let overlayView = CountdownOverlayView(meeting: meeting) { [weak self] in
            self?.dismiss()
        }

        let hostingView = NSHostingView(rootView: overlayView)

        // Panel size depends on whether the details panel will render — taller to
        // accommodate notes/attendees/secondary join link without scrolling the ring.
        let threshold = UserDefaults.standard.object(forKey: "contextPanelMinThreshold") as? Int ?? 0
        let panelHeight: CGFloat = CountdownOverlayView.shouldShowDetailsPanel(for: meeting, threshold: threshold) ? 720 : 560

        // Create a floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: panelHeight),
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
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 210
            let y = screenFrame.midY - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        overlayWindow = panel
        isShowing = true

        // Start the music
        audioManager?.play()
    }

    /// Dismiss the overlay and stop music.
    func dismiss() {
        overlayWindow?.close()
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
}
