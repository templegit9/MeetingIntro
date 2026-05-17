import AppKit
import SwiftUI

/// Manages the floating countdown overlay window.
/// Uses an NSPanel for proper always-on-top behavior.
@MainActor
final class OverlayWindowController: ObservableObject {

    @Published var isShowing: Bool = false

    private var overlayWindow: NSPanel?
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

        // Create a floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
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
            let y = screenFrame.midY - 280
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
}
