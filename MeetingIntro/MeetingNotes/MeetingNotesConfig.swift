import Combine
import Foundation

/// Settings for the transcription + notes pipeline. Keys in Keychain per
/// convention; everything else UserDefaults.
@MainActor
final class MeetingNotesConfig: ObservableObject {

    enum Engine: String, CaseIterable, Identifiable {
        case whisperKit
        case groq
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .whisperKit: return "On-device (WhisperKit) — private, slower"
            case .groq: return "Online (Groq) — fast, uploads audio"
            }
        }
    }

    /// Run the pipeline automatically when a recording finalizes.
    @Published var autoGenerate: Bool {
        didSet { UserDefaults.standard.set(autoGenerate, forKey: Self.k_auto) }
    }

    @Published var engine: Engine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Self.k_engine) }
    }

    /// WhisperKit model name (downloaded on first use). base ≈ 150 MB and fast;
    /// large-v3_turbo ≈ 1.6 GB and noticeably better on accented/overlapping speech.
    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: Self.k_whisperModel) }
    }

    static let whisperModelOptions = ["tiny", "base", "small", "large-v3_turbo"]

    /// Groq key for transcription. Stored in Keychain.
    @Published var groqKey: String {
        didSet {
            if groqKey.isEmpty {
                KeychainStore.delete(Self.keychainAccount)
            } else {
                KeychainStore.set(groqKey, for: Self.keychainAccount)
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        self.autoGenerate = d.object(forKey: Self.k_auto) as? Bool ?? true
        self.whisperModel = d.string(forKey: Self.k_whisperModel) ?? "base"
        self.groqKey = KeychainStore.get(Self.keychainAccount) ?? ""
        // Default engine: groq when a key already exists (fast path), else on-device.
        if let raw = d.string(forKey: Self.k_engine), let stored = Engine(rawValue: raw) {
            self.engine = stored
        } else {
            self.engine = (KeychainStore.get(Self.keychainAccount) ?? "").isEmpty ? .whisperKit : .groq
        }
    }

    func makeEngine() -> TranscriptionEngine {
        switch engine {
        case .whisperKit: return WhisperKitEngine(modelName: whisperModel)
        case .groq: return GroqWhisperEngine(apiKey: groqKey)
        }
    }

    private static let keychainAccount = "groqTranscriptionKey"
    private static let k_auto = "notes_autoGenerate"
    private static let k_engine = "notes_engine"
    private static let k_whisperModel = "notes_whisperModel"
}
