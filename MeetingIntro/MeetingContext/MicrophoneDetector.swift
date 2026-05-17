import CoreAudio
import Foundation

/// Reports whether any process on the system has an input audio device "running" —
/// the standard signal for "another app is using the microphone."
///
/// We enumerate input devices via `kAudioHardwarePropertyDevices`, then for each one
/// register a listener on `kAudioDevicePropertyDeviceIsRunningSomewhere`. We never open
/// any device for capture, so this works without triggering the microphone permission prompt.
@MainActor
final class MicrophoneDetector: ObservableObject {

    @Published private(set) var isMicrophoneInUseElsewhere: Bool = false

    private var inputDeviceIDs: [AudioDeviceID] = []
    private var listenerBlocks: [(AudioDeviceID, AudioObjectPropertyListenerBlock)] = []
    private var devicesListChangedBlock: AudioObjectPropertyListenerBlock?

    init() {
        rebuildDeviceList()
        installDevicesListListener()
        refresh()
    }

    // No explicit deinit cleanup: this detector lives for the app's lifetime
    // (owned by @StateObject in MeetingIntroApp), and the OS reclaims CoreAudio
    // listeners when the process exits. Cleaner than fighting MainActor isolation
    // rules in deinit for a singleton that never goes away.

    // MARK: - Listener setup

    private func installDevicesListListener() {
        var address = Self.devicesPropertyAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.teardownListeners()
                self?.rebuildDeviceList()
                self?.refresh()
            }
        }
        devicesListChangedBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func rebuildDeviceList() {
        inputDeviceIDs = Self.fetchInputDeviceIDs()
        for deviceID in inputDeviceIDs {
            var address = Self.runningPropertyAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            listenerBlocks.append((deviceID, block))
            AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        }
    }

    private func teardownListeners() {
        for (deviceID, block) in listenerBlocks {
            var address = Self.runningPropertyAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        listenerBlocks.removeAll()
    }

    // MARK: - Querying

    private func refresh() {
        isMicrophoneInUseElsewhere = inputDeviceIDs.contains { Self.isDeviceRunningSomewhere($0) }
    }

    private static func fetchInputDeviceIDs() -> [AudioDeviceID] {
        var address = devicesPropertyAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = runningPropertyAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Property addresses

    private static let devicesPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let runningPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
}
