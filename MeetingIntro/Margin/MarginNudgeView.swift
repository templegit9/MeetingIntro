import SwiftUI

/// An unprompted page, with its corner turned up — the paper equivalent of "I noted this
/// for you". It is a page, not a notification: it does not take focus, it does not sit
/// above what you are doing, and leaving it alone is a valid answer that the notebook
/// remembers.
struct MarginFoldedCornerView: View {
    let nudge: MarginNudge
    let onPrimary: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(nudge.kicker)
                .font(.system(size: 10, weight: .semibold, design: .serif))
                .tracking(0.6)
                .foregroundStyle(MarginTheme.amberInk)
            Text(nudge.body)
                .font(.system(size: 12.5, design: .serif))
                .foregroundStyle(MarginTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let why = nudge.why {
                // Nothing appears from nowhere.
                Text(why)
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let primary = nudge.primary {
                    Button(primary.label, action: onPrimary)
                        .buttonStyle(FoldedPrimary())
                }
                Button(nudge.secondaryLabel, action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
            }
            .padding(.top, 1)
        }
        .padding(12)
        .frame(width: MarginTheme.openWidth, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                MarginTheme.paper
                // The turned-up corner. Not an icon — the shape of the page itself.
                Path { path in
                    path.move(to: CGPoint(x: MarginTheme.openWidth - 18, y: 0))
                    path.addLine(to: CGPoint(x: MarginTheme.openWidth, y: 18))
                    path.addLine(to: CGPoint(x: MarginTheme.openWidth, y: 0))
                    path.closeSubpath()
                }
                .fill(MarginTheme.rule)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MarginTheme.clothDark.opacity(0.45), lineWidth: 1)
        )
        .environment(\.colorScheme, .light)
    }
}

private struct FoldedPrimary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .serif))
            .foregroundStyle(MarginTheme.paper)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(MarginTheme.cloth.opacity(configuration.isPressed ? 0.75 : 1),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The inside cover: everything Margin is keeping an eye on, where it came from, and
/// whether decay has quietened it. This page is the answer to "why did it say that?", and
/// it is the reason a watch may never appear from nowhere.
struct MarginWatchesView: View {
    @ObservedObject var engine: MarginNudgeEngine
    @ObservedObject var config: MarginConfig
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                        Text("Back").font(.system(size: 11, design: .serif))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(MarginTheme.cloth)
                Spacer()
                Text("Standing watches")
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .foregroundStyle(MarginTheme.inkSoft)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            Divider().overlay(MarginTheme.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.watches) { watch in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(watch.label)
                                    .font(.system(size: 12, design: .serif))
                                    .foregroundStyle(MarginTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(watch.retired ? "went quiet — ignored twice" : watch.origin.label)
                                    .font(.system(size: 10, design: .serif))
                                    .foregroundStyle(watch.retired ? MarginTheme.amberInk : MarginTheme.inkSoft)
                            }
                            Spacer(minLength: 6)
                            Toggle("", isOn: Binding(
                                get: { watch.enabled && !watch.retired },
                                set: { engine.setWatch(watch.id, enabled: $0) }))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .tint(MarginTheme.cloth)
                        }
                    }

                    Divider().overlay(MarginTheme.rule).padding(.vertical, 2)

                    // The budget, stated where the watches are — the two only make sense
                    // together.
                    Text("At most \(config.foldedCornerBudget) page\(config.foldedCornerBudget == 1 ? "" : "s") a day may show itself, and only in a gap between meetings. Everything else waits on the ribbon.")
                        .font(.system(size: 10.5, design: .serif))
                        .foregroundStyle(MarginTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper(value: Binding(get: { config.foldedCornerBudget },
                                           set: { config.foldedCornerBudget = $0 }), in: 0...6) {
                        Text("Folded corners a day: \(config.foldedCornerBudget)")
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(MarginTheme.ink)
                    }
                    Toggle(isOn: Binding(get: { config.banded }, set: { config.banded = $0 })) {
                        Text("Band it — it won't speak first")
                            .font(.system(size: 11, design: .serif))
                            .foregroundStyle(MarginTheme.ink)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(width: MarginTheme.openWidth, height: 460)
        .background(MarginTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(MarginTheme.clothDark.opacity(0.55), lineWidth: 1))
        .environment(\.colorScheme, .light)
    }
}
