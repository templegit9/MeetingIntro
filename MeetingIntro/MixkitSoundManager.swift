import Foundation
import AVFoundation

/// Curated list of notification sounds from Mixkit (free, royalty-free).
struct MixkitSound: Identifiable, Codable {
    let id: Int
    let name: String
    let category: String

    var downloadURL: URL {
        URL(string: "https://assets.mixkit.co/active_storage/sfx/\(id)/\(id).wav")!
    }

    var localFileName: String {
        "\(id).wav"
    }
}

/// Manages Mixkit sound downloads and playback for notification alerts.
@MainActor
final class MixkitSoundManager: ObservableObject {

    @Published var sounds: [MixkitSound] = MixkitSoundManager.catalog
    @Published var downloadedSoundIDs: Set<Int> = []
    @Published var downloadingIDs: Set<Int> = []
    @Published var selectedSoundID: Int? {
        didSet {
            UserDefaults.standard.set(selectedSoundID, forKey: "selectedMixkitSoundID")
        }
    }

    private var audioPlayer: AVAudioPlayer?

    /// Directory where downloaded sounds are stored.
    private var soundsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MeetingIntro/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        selectedSoundID = UserDefaults.standard.object(forKey: "selectedMixkitSoundID") as? Int
        scanDownloaded()
    }

    /// Check which sounds are already downloaded locally.
    func scanDownloaded() {
        var found: Set<Int> = []
        for sound in sounds {
            let path = soundsDirectory.appendingPathComponent(sound.localFileName)
            if FileManager.default.fileExists(atPath: path.path) {
                found.insert(sound.id)
            }
        }
        downloadedSoundIDs = found
    }

    /// Download a sound from Mixkit.
    func download(_ sound: MixkitSound) {
        guard !downloadedSoundIDs.contains(sound.id) else { return }
        downloadingIDs.insert(sound.id)

        Task.detached { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: sound.downloadURL)
                let destination = await self?.soundsDirectory.appendingPathComponent(sound.localFileName)
                if let destination {
                    try data.write(to: destination)
                }
                await MainActor.run {
                    self?.downloadedSoundIDs.insert(sound.id)
                    self?.downloadingIDs.remove(sound.id)
                }
            } catch {
                await MainActor.run {
                    self?.downloadingIDs.remove(sound.id)
                }
                print("Failed to download sound \(sound.id): \(error)")
            }
        }
    }

    /// Delete a downloaded sound.
    func delete(_ sound: MixkitSound) {
        let path = soundsDirectory.appendingPathComponent(sound.localFileName)
        try? FileManager.default.removeItem(at: path)
        downloadedSoundIDs.remove(sound.id)
        if selectedSoundID == sound.id {
            selectedSoundID = nil
        }
    }

    /// Preview a downloaded sound.
    func preview(_ sound: MixkitSound) {
        let path = soundsDirectory.appendingPathComponent(sound.localFileName)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: path)
            audioPlayer?.play()
        } catch {
            print("Failed to play sound: \(error)")
        }
    }

    /// Get the file URL for the selected notification sound (if any).
    func selectedSoundURL() -> URL? {
        guard let id = selectedSoundID else { return nil }
        let path = soundsDirectory.appendingPathComponent("\(id).wav")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Curated Catalog

    static let catalog: [MixkitSound] = [
        MixkitSound(id: 933,  name: "Bell notification",               category: "Bell"),
        MixkitSound(id: 2870, name: "Correct answer tone",             category: "Tones"),
        MixkitSound(id: 2358, name: "Long pop",                        category: "Pop"),
        MixkitSound(id: 2869, name: "Software interface start",        category: "Interface"),
        MixkitSound(id: 2568, name: "Sci fi click",                    category: "Sci-Fi"),
        MixkitSound(id: 2354, name: "Message pop alert",               category: "Pop"),
        MixkitSound(id: 932,  name: "Happy bells notification",        category: "Bell"),
        MixkitSound(id: 2571, name: "Sci Fi confirmation",             category: "Sci-Fi"),
        MixkitSound(id: 2867, name: "Positive notification",           category: "Tones"),
        MixkitSound(id: 2872, name: "Confirmation tone",               category: "Tones"),
        MixkitSound(id: 2580, name: "Melodical flute music",           category: "Music"),
        MixkitSound(id: 2357, name: "Bubble pop up alert",             category: "Pop"),
        MixkitSound(id: 2576, name: "Clear announce tones",            category: "Tones"),
        MixkitSound(id: 2575, name: "Magic notification ring",         category: "Magic"),
        MixkitSound(id: 2574, name: "Arabian mystery harp",            category: "Music"),
        MixkitSound(id: 2356, name: "Dry pop up notification",         category: "Pop"),
        MixkitSound(id: 2573, name: "Elevator tone",                   category: "Tones"),
        MixkitSound(id: 2572, name: "Doorbell tone",                   category: "Bell"),
        MixkitSound(id: 2577, name: "Guitar notification alert",       category: "Music"),
        MixkitSound(id: 2578, name: "Magic marimba",                   category: "Magic"),
    ]
}
