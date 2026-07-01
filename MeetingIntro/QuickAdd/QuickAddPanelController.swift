import AppKit
import SwiftUI

/// Borderless NSPanel that can take keyboard focus — the overlay panels use
/// `.nonactivatingPanel` and never become key, but Quick Add needs a focused
/// text field, so this subclass opts in.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Spotlight-style floating input for the text-to-calendar feature. Same
/// window-slot pattern as `OverlayWindowController`: one panel at a time,
/// show is idempotent, dismiss tears down.
@MainActor
final class QuickAddPanelController: ObservableObject {

    private var panel: NSPanel?
    private var resignObserver: Any?

    private let service: QuickAddService
    private let config: QuickAddConfig
    /// Injected by AppLifecycleManager.observe once the @StateObjects exist —
    /// same late-wiring pattern as the recording coordinator's notificationManager.
    weak var calendarManager: CalendarManager? {
        didSet {
            // Wire the Quick Add conflict check (Issue #10) to the live calendar.
            service.conflictProvider = { [weak calendarManager] start, end in
                calendarManager?.conflicts(start: start, end: end).map(\.title) ?? []
            }
        }
    }

    init(service: QuickAddService, config: QuickAddConfig) {
        self.service = service
        self.config = config
    }

    /// Screen frame of our status item, found by scanning for the status-bar
    /// window AppKit creates for MenuBarExtra. Class-name sniffing is the only
    /// route — SwiftUI doesn't expose the NSStatusItem. Nil on miss → fallback
    /// placement.
    private func statusItemFrame() -> NSRect? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            return window.frame
        }
        return nil
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        service.reset()

        let width: CGFloat = 560
        let height: CGFloat = 220

        // Anchor directly beneath the menu bar icon (dropdown feel, like the
        // window-switcher palettes). Clamp to screen edges; the notch keeps
        // pointing at the icon even when the panel is clamped.
        var origin = NSPoint.zero
        var notchCenterX: CGFloat? = nil
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            if let item = statusItemFrame() {
                var x = item.midX - width / 2
                x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
                origin = NSPoint(x: x, y: item.minY - height)
                notchCenterX = item.midX - x
            } else {
                origin = NSPoint(x: visible.midX - width / 2, y: visible.maxY - height)
            }
        }

        let view = QuickAddView(
            service: service,
            config: config,
            notchCenterX: notchCenterX,
            onCreate: { [weak self] draft in
                guard let self, let calendarManager = self.calendarManager else { return }
                try await calendarManager.createEvent(from: draft, calendarID: self.config.defaultCalendarID)
            },
            onDismiss: { [weak self] in
                Task { @MainActor [weak self] in self?.dismiss() }
            }
        )

        let hostingView = NSHostingView(rootView: view)

        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(origin)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Click-outside / focus-loss dismisses, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    func dismiss() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.close()
        panel = nil
        service.reset()
    }
}
