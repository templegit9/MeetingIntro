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

    /// Show the compact cancellation notice panel. Position follows the user's
    /// `cancellationOverlayPosition` setting — top-right toast by default, or
    /// centered like the countdown overlay. Replaces any existing notice — a fresh
    /// cancellation always wins. The view auto-dismisses itself after
    /// `CancellationOverlayView.autoDismissAfter`.
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
    }

    func dismissCancellationNotice() {
        cancellationWindow?.close()
        cancellationWindow = nil
    }
}
