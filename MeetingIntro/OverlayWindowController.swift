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

    /// Show the compact cancellation notice panel (top-right of the main screen,
    /// toast-style). Replaces any existing notice — a fresh cancellation always wins.
    /// The view auto-dismisses itself after `CancellationOverlayView.autoDismissAfter`.
    func showCancellation(for meeting: MeetingEvent) {
        cancellationWindow?.close()
        cancellationWindow = nil

        let view = CancellationOverlayView(meeting: meeting) { [weak self] in
            Task { @MainActor [weak self] in self?.dismissCancellationNotice() }
        }
        let hostingView = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 240
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

        // Top-right corner, toast-style — distinct placement from the centered
        // countdown overlay so simultaneous display doesn't overlap.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - panelWidth - 20
            let y = frame.maxY - panelHeight - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        cancellationWindow = panel
    }

    func dismissCancellationNotice() {
        cancellationWindow?.close()
        cancellationWindow = nil
    }
}
