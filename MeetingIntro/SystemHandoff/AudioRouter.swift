import CoreAudio
import Foundation

/// CoreAudio wrapper for reading and changing the system's default output device.
///
/// Equivalent of "click the volume control and pick a different output" — but
/// programmatic. No new entitlements needed; this is allowed in the App Sandbox.
@MainActor
final class AudioRouter: ObservableObject {

    struct OutputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transportType: UInt32

        var isBluetooth: Bool {
            transportType == kAudioDeviceTransportTypeBluetooth
                || transportType == kAudioDeviceTransportTypeBluetoothLE
        }
        var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    }

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var currentDeviceID: AudioDeviceID = 0

    private var devicesListBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        installListeners()
    }

    // MARK: - Public API

    /// Set the system default output device. Returns true if CoreAudio reports
    /// success AND the round-tripped read matches.
    @discardableResult
    func setDefaultOutput(deviceID: AudioDeviceID) -> Bool {
        var device = deviceID
        var address = Self.defaultOutputAddress
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &device
        )
        guard status == noErr else { return false }
        refresh()
        return currentDeviceID == deviceID
    }

    /// First device matching the predicate, or nil. Useful for "find AirPods by UID."
    func device(matching predicate: (OutputDevice) -> Bool) -> OutputDevice? {
        devices.first(where: predicate)
    }

    /// Convenience: the built-in output device, used as a default fallback.
    var builtInOutput: OutputDevice? { devices.first(where: { $0.isBuiltIn }) }

    // MARK: - Refresh

    private func refresh() {
        currentDeviceID = Self.fetchDefaultOutputDeviceID()
        devices = Self.fetchOutputDevices()
    }

    private func installListeners() {
        var devicesAddr = Self.devicesAddress
        let listDevicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        devicesListBlock = listDevicesBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, .main, listDevicesBlock)

        var defaultAddr = Self.defaultOutputAddress
        let defaultDeviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.defaultDeviceBlock = defaultDeviceBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main, defaultDeviceBlock)
    }

    // MARK: - CoreAudio helpers

    private static func fetchDefaultOutputDeviceID() -> AudioDeviceID {
        var address = defaultOutputAddress
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private static func fetchOutputDevices() -> [OutputDevice] {
        var address = devicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id -> OutputDevice? in
            guard hasOutputStreams(id) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown"
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            let transport = uint32Property(deviceID: id, selector: kAudioDevicePropertyTransportType) ?? 0
            return OutputDevice(id: id, uid: uid, name: name, transportType: transport)
        }
        .sorted { $0.name < $1.name }
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    private static func uint32Property(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Property addresses

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}
