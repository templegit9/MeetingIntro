import AVFoundation
import Foundation

/// Manages audio playback for the meeting countdown.
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published State

    @Published var isPlaying: Bool = false
    @Published var currentFileName: String?
    @Published var volume: Float = 0.7

    // MARK: - Configuration Keys

    private static let musicFileBookmarkKey = "musicFileBookmark"
    private static let volumeKey = "musicVolume"

    // MARK: - Private

    private var audioPlayer: AVAudioPlayer?
    private var fadeTimer: Timer?

    init() {
        let storedVolume = UserDefaults.standard.float(forKey: Self.volumeKey)
        if storedVolume > 0 { volume = storedVolume }
        loadCurrentFileName()
    }

    // MARK: - File Selection

    /// The URL resolved from the stored security-scoped bookmark.
    var musicFileURL: URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.musicFileBookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            // Re-save the bookmark
            saveMusicFile(url: url)
        }
        return url
    }

    /// Save a selected music file URL as a security-scoped bookmark.
    func saveMusicFile(url: URL) {
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        UserDefaults.standard.set(bookmarkData, forKey: Self.musicFileBookmarkKey)
        currentFileName = url.lastPathComponent
    }

    /// Update volume and persist.
    func setVolume(_ newVolume: Float) {
        volume = newVolume
        audioPlayer?.volume = newVolume
        UserDefaults.standard.set(newVolume, forKey: Self.volumeKey)
    }

    // MARK: - Playback

    /// Start playing the selected music file.
    func play() {
        guard let url = musicFileURL else { return }

        // Access the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else { return }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.volume = volume
            audioPlayer?.numberOfLoops = -1 // Loop until stopped
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isPlaying = true
        } catch {
            print("AudioManager: Failed to play audio: \(error.localizedDescription)")
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Stop playback immediately.
    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false

        // Stop accessing the security-scoped resource
        musicFileURL?.stopAccessingSecurityScopedResource()
    }

    /// Fade out over the given duration, then stop.
    func fadeOut(duration: TimeInterval = 2.0) {
        guard let player = audioPlayer, player.isPlaying else {
            stop()
            return
        }

        let steps = 20
        let stepDuration = duration / Double(steps)
        let volumeStep = player.volume / Float(steps)
        var currentStep = 0

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                currentStep += 1
                if currentStep >= steps {
                    timer.invalidate()
                    self?.stop()
                } else {
                    self?.audioPlayer?.volume -= volumeStep
                }
            }
        }
    }

    // MARK: - Private

    private func loadCurrentFileName() {
        currentFileName = musicFileURL?.lastPathComponent
    }
}
