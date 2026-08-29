import SwiftUI

/// One plugin in the Plugins grid: what it is, whether it's on, and **what it's doing
/// right now**.
///
/// The status line is the reason this is a grid rather than the list it replaced. A list
/// of descriptions is something you read once and never open again; a status line
/// ("hidden — nothing to show", "3 folders watched") makes the tab worth returning to.
/// Every plugin already computes that string somewhere — this just surfaces it.
struct PluginTile: View {

    enum Status {
        /// Running and doing something.
        case active(String)
        /// On, but nothing to do at the moment.
        case idle(String)
        /// On, but held back or needing attention.
        case attention(String)

        var text: String {
            switch self {
            case .active(let t), .idle(let t), .attention(let t): return t
            }
        }

        var color: Color {
            switch self {
            case .active: return .green
            case .idle: return .secondary
            case .attention: return .orange
            }
        }
    }

    let symbol: String
    let tint: Color
    let name: String
    let blurb: String
    var status: Status?
    @Binding var isEnabled: Bool
    /// Not built yet: shown muted, with no switch, so the grid can advertise what's
    /// coming without pretending it's available.
    var comingSoon: Bool = false
    /// Tapping the tile body opens the plugin — its window, or its settings sheet.
    var onOpen: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(comingSoon ? Color.secondary : tint)
                    .frame(width: 20)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(comingSoon ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }

            Text(blurb)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                if comingSoon {
                    Text("Coming soon")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                } else if let status {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if !comingSoon {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .controlSize(.mini)
                }
            }
        }
        .padding(10)
        .frame(minHeight: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering && !comingSoon ? 0.08 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(comingSoon ? 0.06 : 0.10), lineWidth: 1)
        )
        .opacity(comingSoon ? 0.65 : 1)
        // The toggle sits above this, so a click on the switch flips it without also
        // opening the plugin.
        .contentShape(Rectangle())
        .onTapGesture { if !comingSoon, isEnabled { onOpen?() } }
        .onHover { hovering = $0 }
        .help(comingSoon ? "Not available yet" : (isEnabled ? "Open \(name)" : "Turn on to use \(name)"))
    }
}

/// Three columns that reflow rather than a rigid 3×3 — with four plugins today a fixed
/// grid would be five empty holes, and the count changes as plugins land.
enum PluginGridLayout {
    static let columns = [GridItem(.adaptive(minimum: 190), spacing: 10)]
}
