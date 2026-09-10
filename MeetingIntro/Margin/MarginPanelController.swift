import AppKit
import Combine
import SwiftUI

/// Margin lives in a panel of its own, bottom-right, all day.
///
/// **Always present, never loud.** It rests at 30% opacity and brightens as the pointer
/// nears it — no hot zone to discover, no icon that appears from nowhere. Clicking it or
/// pressing ⌥Space opens the cover; escape closes it.
///
/// It is a panel and not a `Window` scene for the same reasons the countdown overlay is:
/// SwiftUI window scenes can't be non-activating, can't sit above a full-screen app, and
/// can't be positioned. The one thing this panel *does* need that the overlay doesn't is
/// to become key while open, so you can type on the page — hence `KeyableMarginPanel`.
@MainActor
final class MarginPanelController: NSObject, ObservableObject {

    private var panel: KeyableMarginPanel?
    private var hotKey: MarginHotKey?
    private var cancellables = Set<AnyCancellable>()

    private let agent: MarginAgent
    private let config: MarginConfig
    let nudges: MarginNudgeEngine
    let roots: MarginRoots

    @Published private(set) var isOpen = false
    @Published private(set) var hovering = false

    /// A folded page that goes unanswered folds back down and counts as an ignore. Left
    /// on screen forever it would be a notification, which is the thing it isn't.
    private static let foldTimeout: TimeInterval = 180
    private var foldTimer: Timer?

    @Published var showingWatches = false

    init(agent: MarginAgent, config: MarginConfig, nudges: MarginNudgeEngine, roots: MarginRoots) {
        self.agent = agent
        self.config = config
        self.nudges = nudges
        self.roots = roots
        super.init()

        // A corner folds itself: the panel grows to show one page, WITHOUT taking focus
        // or activating the app. Whatever you were typing stays where it was.
        // Re-fit the page when its content changes — an answer arriving, a tick added —
        // and not on every publish.
        agent.$turns
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in if self?.isOpen == true { self?.resize() } }
            }
            .store(in: &cancellables)

        nudges.$folded
            .sink { [weak self] nudge in
                Task { @MainActor in self?.presentFold(nudge) }
            }
            .store(in: &cancellables)

        // Visibility follows the plugin switch, live.
        config.$isEnabled
            .sink { [weak self] enabled in
                Task { @MainActor in enabled ? self?.show() : self?.hide() }
            }
            .store(in: &cancellables)

        config.$summonShortcutEnabled
            .sink { [weak self] on in
                Task { @MainActor in on ? self?.registerHotKey() : self?.hotKey?.unregister() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.reposition() } }
            .store(in: &cancellables)
    }

    // MARK: Presence

    func show() {
        guard panel == nil else { return }
        let panel = KeyableMarginPanel(
            contentRect: NSRect(origin: .zero, size: closedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Built ONCE. Replacing the hosting view on every published change is what made
        // the page jump and swallowed both focus and clicks — the view under the pointer
        // was a different view by the time the click landed. The SwiftUI tree observes
        // the agent and the controller directly instead.
        panel.contentView = NSHostingView(rootView: rootView)
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
        if config.summonShortcutEnabled { registerHotKey() }
    }

    func hide() {
        close()
        hotKey?.unregister()
        hotKey = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func registerHotKey() {
        guard hotKey == nil else { return }
        let key = MarginHotKey { [weak self] in Task { @MainActor in self?.toggle() } }
        key.register()
        hotKey = key
    }

    // MARK: Opening

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard config.isEnabled else { return }
        if panel == nil { show() }
        isOpen = true
        resize()
        // Only while open does it take focus — a closed notebook must never steal a key
        // press from what you were doing.
        panel?.acceptsKey = true
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel?.acceptsKey = false
        panel?.resignKey()
        resize()
    }

    // MARK: Layout

    private var closedSize: NSSize {
        NSSize(width: MarginTheme.coverSize.width + 6, height: MarginTheme.coverSize.height + 14)
    }

    /// A page is a fixed size. Re-measuring it as content arrives would make the panel
    /// twitch under the pointer, which is exactly the jumpiness this replaced.
    // MARK: Folded corners

    private func presentFold(_ nudge: MarginNudge?) {
        foldTimer?.invalidate()
        guard panel != nil, !isOpen else { return }
        resize()
        guard let nudge else { return }
        let timer = Timer(timeInterval: Self.foldTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.nudges.ignored(nudge) }
        }
        RunLoop.main.add(timer, forMode: .common)
        foldTimer = timer
    }

    func actOnFold(_ nudge: MarginNudge) {
        foldTimer?.invalidate()
        guard let primary = nudge.primary else { nudges.accepted(nudge); return }
        Task { @MainActor in
            do {
                let outcome = try await primary.action()
                agent.recordTick(outcome, undo: nil)
            } catch {
                agent.recordTick("Couldn't: \(error.localizedDescription)", undo: nil)
            }
            nudges.accepted(nudge)
        }
    }

    func dismissFold(_ nudge: MarginNudge) {
        foldTimer?.invalidate()
        nudges.ignored(nudge)
    }

    /// Fix 7: the page ends where the answer ends. Measured from the content at the real
    /// page width — a width-pinned probe, because `fittingSize` on an unpinned view
    /// reports the height of the view's *ideal* width, a layout that never happens.
    ///
    /// Recomputed only when the content changes, never on every publish: measuring on
    /// each tick is what would make the panel twitch under the pointer.
    private var openSize: NSSize {
        let measured = MarginPageView.fittingHeight(agent: agent, config: config, ribbon: nudges.onRibbon)
        return NSSize(width: MarginTheme.openWidth, height: min(max(measured, 170), 620))
    }

    private func resize() {
        guard let panel else { return }
        let size: NSSize
        if isOpen {
            size = openSize
        } else if nudges.folded != nil {
            size = NSSize(width: MarginTheme.openWidth, height: 150)
        } else {
            size = closedSize
        }
        panel.setContentSize(size)
        reposition()
    }

    /// Bottom-right, inset from the visible frame so it clears the Dock.
    private func reposition() {
        guard let panel, let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - MarginTheme.inset,
                                     y: frame.minY + MarginTheme.inset))
    }

    private var rootView: some View {
        MarginRootView(agent: agent, config: config, nudges: nudges, controller: self)
    }

    // MARK: Cover state

    var coverState: MarginCoverView.State {
        if agent.problem != nil { return .offline }
        if agent.isThinking { return .working }
        let waiting = agent.turns.filter { $0.action?.kind == .change && $0.outcome == nil }.count
            + nudges.onRibbon.count
        if waiting > 0 { return .needsYou(waiting) }
        if config.banded { return .banded }
        return .idle
    }

    func setHovering(_ value: Bool) { hovering = value }
}

/// The panel only becomes key while the notebook is open. Closed, it must be invisible to
/// the keyboard — otherwise a small green book on your desktop starts eating keystrokes.
final class KeyableMarginPanel: NSPanel {
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// Switches between the closed cover and the open page, and carries the resting opacity.
private struct MarginRootView: View {
    @ObservedObject var agent: MarginAgent
    @ObservedObject var config: MarginConfig
    @ObservedObject var nudges: MarginNudgeEngine
    @ObservedObject var controller: MarginPanelController

    @State private var hovering = false

    var body: some View {
        Group {
            if controller.isOpen {
                if controller.showingWatches {
                    MarginWatchesView(engine: nudges, config: config, roots: controller.roots) {
                        controller.showingWatches = false
                    }
                } else {
                    MarginPageView(agent: agent, config: config,
                                   ribbon: nudges.onRibbon,
                                   roots: controller.roots,
                                   onWatches: { controller.showingWatches = true },
                                   onClose: { controller.close() })
                }
            } else if let nudge = nudges.folded {
                MarginFoldedCornerView(
                    nudge: nudge,
                    onPrimary: { controller.actOnFold(nudge) },
                    onDismiss: { controller.dismissFold(nudge) })
            } else {
                Button { controller.open() } label: {
                    MarginCoverView(state: controller.coverState, hovering: hovering)
                }
                .buttonStyle(.plain)
                // Resting at 30%, full strength as the pointer arrives. Anything waiting
                // on the ribbon stays legible regardless — it is the one state that has
                // earned your attention.
                .opacity(hovering || isWaiting ? 1 : config.restingOpacity)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .onHover { hovering = $0 }
                .help("Margin — ⌥Space")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var isWaiting: Bool {
        if case .needsYou = controller.coverState { return true }
        return !nudges.onRibbon.isEmpty
    }
}
