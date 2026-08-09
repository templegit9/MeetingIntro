import AppKit
import SwiftUI

/// Owns the ticker panel: a borderless, click-through strip pinned to the top centre of
/// the screen, in the empty middle of the menu bar row.
///
/// Same panel machinery as the countdown/auto-join overlays, with three differences that
/// are load-bearing — don't drop them:
/// 1. **Level `.statusBar`** so it draws over the menu bar (the menu bar's own window
///    level is just below). `.floating` would put it *under* the menu bar and the strip
///    would be invisible at the top of the screen.
/// 2. **`ignoresMouseEvents = true`** — the strip sits on top of the menu bar row, so if
///    it took clicks it would eat clicks meant for app menus and status icons. It is
///    informational glass, by explicit design decision.
/// 3. **Notch fallback** — on a Mac with a camera housing, top-centre *is* the notch, so
///    the strip would be sliced in half. When `safeAreaInsets.top > 0` we drop it just
///    below the menu bar instead.
@MainActor
final class TickerWindowController: ObservableObject {

    private var panel: NSPanel?
    private var hostingView: NSHostingView<TickerBanner>?
    /// Last rendered feed + speed, so `show` can be called every refresh cheaply.
    private var lastItems: [TickerItem] = []
    private var lastStyle: TickerStyle?

    var diagnosticLog: DiagnosticLog?

    /// Height of the strip. Sized to sit inside a standard menu bar row (~24pt).
    private static let panelHeight: CGFloat = 22
    /// Gap below the menu bar when the notch forces us out of the menu bar row.
    private static let notchDropGap: CGFloat = 4

    var isShowing: Bool { panel != nil }

    /// Show or update the strip. Idempotent: repeated calls with the same feed only
    /// reposition, they don't rebuild the view (which would restart the crawl).
    func show(items: [TickerItem], style: TickerStyle, width: CGFloat) {
        guard !items.isEmpty else { hide(); return }

        let contentChanged = items != lastItems || style != lastStyle
        lastItems = items
        lastStyle = style

        let banner = TickerBanner(items: items, style: style)

        if let panel, let hostingView {
            if contentChanged { hostingView.rootView = banner }
            position(panel, width: width)
            return
        }

        let host = NSHostingView(rootView: banner)
        let created = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.contentView = host
        created.isFloatingPanel = true
        // Above the menu bar — see the class comment.
        created.level = .statusBar
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.hidesOnDeactivate = false
        // Click-through: never intercept the mouse (user's explicit choice).
        created.ignoresMouseEvents = true
        created.appearance = NSAppearance(named: .darkAqua)

        position(created, width: width)
        created.orderFrontRegardless()

        panel = created
        hostingView = host
        diagnosticLog?.info(.ticker, "Ticker shown — \(items.count) item(s), \(Int(style.speed))pt/s, leader: \(style.leader.rawValue)")
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        hostingView = nil
        lastItems = []
        diagnosticLog?.info(.ticker, "Ticker hidden")
    }

    /// Re-centre on the current screen — called on every refresh and on screen changes,
    /// so plugging in a display or changing resolution just works.
    func reposition(width: CGFloat) {
        guard let panel else { return }
        position(panel, width: width)
    }

    private func position(_ panel: NSPanel, width: CGFloat) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let clampedWidth = min(max(width, TickerConfig.widthRange.lowerBound), frame.width - 40)

        // Menu bar height = the slice `visibleFrame` gives up at the top.
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        let hasNotch = screen.safeAreaInsets.top > 0

        let y: CGFloat
        if hasNotch {
            // Camera housing owns top-centre — drop below the menu bar entirely.
            y = frame.maxY - menuBarHeight - Self.panelHeight - Self.notchDropGap
        } else {
            // Sit inside the menu bar row, vertically centred in it.
            y = frame.maxY - menuBarHeight + (menuBarHeight - Self.panelHeight) / 2
        }

        let x = frame.midX - clampedWidth / 2
        panel.setFrame(NSRect(x: x, y: y, width: clampedWidth, height: Self.panelHeight), display: true)
    }
}
