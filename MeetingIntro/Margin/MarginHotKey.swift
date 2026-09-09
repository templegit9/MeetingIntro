import AppKit
import Carbon.HIToolbox

/// ⌥Space, registered as a real system hotkey.
///
/// **Not an event tap.** A tap could catch a Space+N chord, but it needs Accessibility
/// permission and fires on any fast "space then n" — "in a note", "on Monday". Carbon's
/// `RegisterEventHotKey` needs no permission, cannot misfire while typing, and is the
/// same mechanism every launcher on macOS uses.
final class MarginHotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void

    /// `k` in a four-char code is arbitrary; it only has to be unique within the app.
    private static let signature: OSType = 0x4D524750 // 'MRGP'

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    func register() {
        guard ref == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<MarginHotKey>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if id.signature == MarginHotKey.signature {
                DispatchQueue.main.async { hotKey.onPress() }
            }
            return noErr
        }, 1, &eventType, context, &handler)

        var hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        _ = hotKeyID
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}
