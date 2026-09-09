import SwiftUI

/// The closed notebook: a small cloth cover with a ribbon out of the bottom.
///
/// State is carried as a **rim tint and the ribbon**, never on the pages — the pages stay
/// paper-white so that what is written on them is always the content, never the status.
struct MarginCoverView: View {

    enum State: Equatable {
        case idle
        /// Pages flick past. Speed never changes — only whether it's moving — so the
        /// motion reads as "working", not as "nearly done".
        case working
        /// Ribbon amber and lifted: something is marked and waiting.
        case needsYou(Int)
        case done
        /// The elastic band is on: it still opens, it just won't speak first.
        case banded
        /// Outline only. It still takes notes; they're written up when you reconnect.
        case offline
    }

    let state: State
    let hovering: Bool

    @SwiftUI.State private var sway = false
    @SwiftUI.State private var flutter = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ribbon
            cover
            if case .done = state { tick }
            if case .banded = state { band }
        }
        .frame(width: MarginTheme.coverSize.width, height: MarginTheme.coverSize.height + 8)
        // One degree, once every seven seconds. Present, not animated at you.
        .rotationEffect(.degrees(sway ? 1 : -1), anchor: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { sway = true }
            if case .working = state { startFlutter() }
        }
        .onChange(of: state) { _, new in
            if case .working = new { startFlutter() } else { flutter = false }
        }
    }

    private var cover: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinearGradient(
                    colors: isOffline ? [.clear, .clear] : [MarginTheme.cloth, MarginTheme.clothDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(rimTint, lineWidth: isOffline ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.22), radius: hovering ? 7 : 4, y: 2)

            // The spine: the edge the cover swings from.
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(isOffline ? 0.25 : 0.30))
                .frame(width: 3)
                .padding(.vertical, 3)
                .padding(.leading, 3)

            // Page edges, and the flutter that means "working".
            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MarginTheme.paper.opacity(isOffline ? 0.35 : 0.85))
                        .frame(width: 2)
                        .offset(y: flutter ? -1.5 : 1.5)
                        .animation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07), value: flutter)
                }
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: MarginTheme.coverSize.width, height: MarginTheme.coverSize.height)
    }

    /// Hangs below the cover. Amber and longer when something needs you.
    private var ribbon: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(needsAttention ? MarginTheme.ribbonAmber : MarginTheme.ribbon)
            .frame(width: 5, height: needsAttention ? 14 : 9)
            .offset(x: 8, y: needsAttention ? 5 : 3)
            .animation(.easeOut(duration: 0.25), value: needsAttention)
    }

    private var tick: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(MarginTheme.paper)
            .offset(y: -12)
            .transition(.opacity)
    }

    /// The elastic band, drawn across the cover.
    private var band: some View {
        Rectangle()
            .fill(MarginTheme.clothDark.opacity(0.85))
            .frame(width: 3.5, height: MarginTheme.coverSize.height + 4)
            .offset(x: 6, y: -4)
    }

    private var needsAttention: Bool { if case .needsYou = state { return true }; return false }
    private var isOffline: Bool { if case .offline = state { return true }; return false }

    private var rimTint: Color {
        switch state {
        case .needsYou: return MarginTheme.ribbonAmber.opacity(0.9)
        case .working:  return MarginTheme.paper.opacity(0.45)
        case .offline:  return MarginTheme.inkSoft.opacity(0.7)
        case .banded:   return MarginTheme.clothDark
        default:        return .black.opacity(0.35)
        }
    }

    private func startFlutter() {
        flutter = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { flutter = true }
    }
}
