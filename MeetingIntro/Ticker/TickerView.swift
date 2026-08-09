import AppKit
import SwiftUI

/// The crawl itself — a true chyron: the item strip slides right-to-left continuously
/// and wraps seamlessly.
///
/// **Why a repeating `.linear` animation and not `TimelineView(.animation)`:** the
/// offset animation is handed to Core Animation once and runs on the GPU, so a strip
/// that crawls all day costs ~nothing. A TimelineView would re-render the SwiftUI body
/// every display frame for the same visual result — on the menu bar, all day, that's a
/// battery bug waiting to happen. Keep it this way.
struct TickerView: View {

    let items: [TickerItem]
    /// Leader character, per-item icons, bob, and speed.
    let style: TickerStyle

    /// Width of one copy of the strip, measured at layout time. The strip is rendered
    /// twice back-to-back and offset by exactly this much, which is what makes the wrap
    /// seamless (the second copy is in the first's old position when the cycle restarts).
    @State private var stripWidth: CGFloat = 0
    @State private var animating = false
    /// Drives the leader's vertical bob (Core Animation, same as the crawl itself).
    @State private var bobbing = false

    private static let itemSpacing: CGFloat = 26
    private static let separator = "•"

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Self.itemSpacing) {
                strip
                strip
            }
            .fixedSize()
            .offset(x: animating ? -(stripWidth + Self.itemSpacing) : 0)
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            // Fade both ends so items enter and leave instead of popping at a hard edge.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        }
        .onPreferenceChange(TickerStripWidthKey.self) { width in
            guard width > 0, abs(width - stripWidth) > 0.5 else { return }
            stripWidth = width
            restart()
        }
        .onChange(of: style.speed) { _, _ in restart() }
        .onDisappear { animating = false }
    }

    /// One pass of every item. Rendered twice by `body`.
    ///
    /// The chosen character leads **each message**, not the strip as a whole — it takes
    /// the place of that item's status glyph, so every line is hauled along by its own
    /// character rather than one mascot towing the entire feed.
    private var strip: some View {
        HStack(spacing: Self.itemSpacing) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    if !style.leader.isNone {
                        leaderView
                    } else if style.showItemIcons {
                        Image(systemName: item.symbol)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(item.text)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(Self.separator)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.28))
                        .padding(.leading, 3)
                }
                .foregroundStyle(color(for: item.tint))
                .fixedSize()
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TickerStripWidthKey.self, value: proxy.size.width)
            }
        )
    }

    /// The character in front of a message, pulling that line along. Symbol leaders
    /// inherit the item's tint (like the status glyph they replace); emoji are colour
    /// glyphs and ignore it.
    @ViewBuilder private var leaderView: some View {
        Group {
            if let emoji = style.leader.emoji {
                // Emoji carry their own internal padding, so they need a point or two
                // more than the text to read at the same visual weight.
                Text(emoji).font(.system(size: 14))
            } else if let symbol = style.leader.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .offset(y: bobbing ? -1.5 : 1.5)
        .onAppear {
            guard style.bounce else { return }
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                bobbing = true
            }
        }
    }

    private func color(for tint: TickerItem.TickerTint) -> Color {
        switch tint {
        case .neutral: return .white.opacity(0.88)
        case .accent:  return Color(red: 0.45, green: 0.80, blue: 1.0)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.35)
        case .alert:   return Color(red: 1.0, green: 0.48, blue: 0.48)
        case .success: return Color(red: 0.45, green: 0.85, blue: 0.55)
        }
    }

    /// Restart the crawl from the right whenever the content or speed changes. Setting
    /// `animating` false without animation snaps back, then the linear repeat begins.
    private func restart() {
        guard stripWidth > 0, style.speed > 0 else { return }
        let distance = stripWidth + Self.itemSpacing
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { animating = false }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: distance / style.speed).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
    }
}

private struct TickerStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The strip's chrome — a translucent dark pill sized to the menu bar row. Forced dark
/// (like the countdown/cancellation panels) so white text stays legible whether the
/// menu bar underneath is light or dark.
struct TickerBanner: View {
    let items: [TickerItem]
    let style: TickerStyle

    var body: some View {
        TickerView(items: items, style: style)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .colorScheme(.dark)
    }
}
