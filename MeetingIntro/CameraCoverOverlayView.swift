import SwiftUI

/// The camera-cover nudge as one of the app's own floating panels.
///
/// **Why a panel and not just the notification:** a notification banner is held back by
/// Do Not Disturb, and there's no way around that without the time-sensitive entitlement
/// (restricted, needs a provisioning profile, and macOS downgrades it *silently* when it
/// isn't authorized — a failure you'd never see). An `NSPanel` is just a window, so Focus
/// has no say over it. This is what makes "remind me even in Do Not Disturb" actually
/// work rather than appear to.
struct CameraCoverOverlayView: View {

    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "web.camera.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.85))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1))
        )
        // Dark-designed like every other panel in the app; without this it renders light
        // in light mode and the white text vanishes.
        .colorScheme(.dark)
    }
}
