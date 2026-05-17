import Foundation

/// Reports whether any process is currently capturing the main display.
///
/// Currently a stub. The unprivileged signal we wanted (`CGDisplayIsCaptured`) is
/// deprecated on macOS 14+; every remaining alternative (`SCShareableContent`,
/// `CGWindowListCreateImage`, etc.) requires Screen Recording permission, which would
/// be a heavy ask for a single rule in the Smart tab. We keep the detector here so
/// the wiring is in place; flipping the screen-share rule on later is a single-file change.
///
/// TODO: revisit when we're ready to request Screen Recording permission, or when
/// Apple ships a privacy-preserving "is being captured" API.
@MainActor
final class ScreenCaptureDetector: ObservableObject {
    @Published private(set) var isScreenCaptured: Bool = false
}
