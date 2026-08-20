import CoreMediaIO
import Foundation

/// Reports whether any process on the system is streaming from a camera — the direct
/// counterpart to `MicrophoneDetector`, on CoreMediaIO instead of CoreAudio:
///
///   CoreAudio   : `kAudioDevicePropertyDeviceIsRunningSomewhere`
///   CoreMediaIO : `kCMIODevicePropertyDeviceIsRunningSomewhere`
///
/// **We never open a device for capture.** Reading a property doesn't start a stream, so
/// this needs no camera permission, lights no green LED, and puts no dot in the menu bar.
/// That distinction is the whole reason the camera-cover reminder can exist without the
/// app ever looking through your camera — verified on an M5 MacBook Pro (macOS 26.1),
/// where a listener correctly caught FaceTime starting and stopping the camera while no
/// permission prompt appeared.
///
/// **Subscribe, don't poll.** A cold one-shot read from a process with no listener
/// registered was observed returning stale `false` while the camera was live. Registering
/// the listeners (as this does at init) is what makes the value trustworthy — so state is
/// kept from callbacks, never re-derived by a bare read somewhere else.
///
/// Every camera counts: a Mac exposes the built-in camera, Desk View, Continuity Camera,
/// and any external webcam as separate devices, so we OR across all of them.
@MainActor
final class CameraUseDetector: ObservableObject {

    @Published private(set) var isCameraInUse: Bool = false

    private var deviceIDs: [CMIOObjectID] = []
    private var listeners: [(CMIOObjectID, CMIOObjectPropertyListenerBlock)] = []
    private var devicesListChangedBlock: CMIOObjectPropertyListenerBlock?

    init() {
        rebuildDeviceList()
        installDevicesListListener()
        refresh()
    }

    // No deinit cleanup, for the same reason as MicrophoneDetector: this lives for the
    // app's lifetime and the OS reclaims the listeners at exit.

    // MARK: - Listener setup

    /// Cameras come and go — plugging in a webcam, an iPhone offering Continuity Camera —
    /// so re-enumerate whenever the device list changes.
    private func installDevicesListListener() {
        var address = Self.devicesPropertyAddress
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.teardownListeners()
                self?.rebuildDeviceList()
                self?.refresh()
            }
        }
        devicesListChangedBlock = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, .main, block)
    }

    private func rebuildDeviceList() {
        deviceIDs = Self.fetchDeviceIDs()
        for deviceID in deviceIDs {
            var address = Self.runningPropertyAddress
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            listeners.append((deviceID, block))
            CMIOObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        }
    }

    private func teardownListeners() {
        for (deviceID, block) in listeners {
            var address = Self.runningPropertyAddress
            CMIOObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        listeners.removeAll()
    }

    // MARK: - Querying

    private func refresh() {
        isCameraInUse = deviceIDs.contains { Self.isDeviceRunningSomewhere($0) }
    }

    private static func fetchDeviceIDs() -> [CMIOObjectID] {
        var address = devicesPropertyAddress
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func isDeviceRunningSomewhere(_ deviceID: CMIOObjectID) -> Bool {
        var address = runningPropertyAddress
        var running: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(deviceID, &address, 0, nil,
                                        UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Property addresses

    private static let devicesPropertyAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private static let runningPropertyAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
}
