import AVFoundation
import Foundation

/// Manages text-to-speech voice reminders before meetings.
/// Uses macOS AVSpeechSynthesizer for natural-sounding announcements.
@MainActor
final class VoiceReminderManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "voiceReminderEnabled") }
    }

    @Published var reminderMinutesBefore: Int {
        didSet { UserDefaults.standard.set(reminderMinutesBefore, forKey: "voiceReminderMinutes") }
    }

    @Published var selectedVoiceId: String {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "voiceReminderId") }
    }

    @Published var userName: String {
        didSet { UserDefaults.standard.set(userName, forKey: "voiceReminderUserName") }
    }

    @Published var isSpeaking: Bool = false

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private var spokenMeetingIDs: Set<String> = []

    // MARK: - Phrase Templates

    /// Varied phrase templates. `{name}`, `{minutes}`, `{meeting}`, and `{organizer}` are placeholders.
    private let phraseTemplates: [String] = [
        "Hi {name}, it's {minutes} minutes before your meeting: {meeting}.",
        "Hey {name}, heads up! Your meeting, {meeting}, starts in {minutes} minutes.",
        "{name}, just a reminder. {meeting} begins in {minutes} minutes.",
        "Attention {name}. You have {meeting} coming up in {minutes} minutes.",
        "Quick reminder {name}! {meeting} starts in {minutes} minutes. Time to get ready.",
        "{name}, {minutes} minutes until {meeting}. You got this!",
        "Hey {name}, {meeting} is about to start in {minutes} minutes. Wrap up what you're doing.",
        "Hi {name}! Just {minutes} minutes left before {meeting}. Don't be late!",
    ]

    // MARK: - Init

    override init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "voiceReminderEnabled")
        let storedMinutes = UserDefaults.standard.integer(forKey: "voiceReminderMinutes")
        self.reminderMinutesBefore = storedMinutes > 0 ? storedMinutes : 5
        self.selectedVoiceId = UserDefaults.standard.string(forKey: "voiceReminderId") ?? ""
        self.userName = UserDefaults.standard.string(forKey: "voiceReminderUserName") ?? "there"
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak a reminder for the given meeting if it hasn't been spoken already.
    func speakReminderIfNeeded(for meeting: MeetingEvent) {
        guard isEnabled else { return }
        guard !spokenMeetingIDs.contains(meeting.id) else { return }

        spokenMeetingIDs.insert(meeting.id)

        let phrase = buildPhrase(for: meeting)
        speak(phrase)
    }

    /// Speak a test phrase.
    func speakTest() {
        let testPhrase = "Hi \(userName), it's \(reminderMinutesBefore) minutes before your meeting: Team Standup."
        speak(testPhrase)
    }

    /// Speak an arbitrary phrase (e.g. a task deadline). Respects the enable toggle.
    func speak(phrase: String) {
        guard isEnabled else { return }
        speak(phrase)
    }

    /// Stop any current speech.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Reset spoken meeting tracking (e.g., daily reset).
    func resetSpokenState() {
        spokenMeetingIDs.removeAll()
    }

    /// Whether a meeting should trigger a voice reminder right now.
    func shouldRemind(for meeting: MeetingEvent) -> Bool {
        guard isEnabled else { return false }
        guard !spokenMeetingIDs.contains(meeting.id) else { return false }
        let threshold = TimeInterval(reminderMinutesBefore * 60)
        return meeting.timeUntilStart > 0 && meeting.timeUntilStart <= threshold
    }

    /// Get available system voices suitable for reminders.
    var availableVoices: [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.starts(with: "en") } // English voices only
            .sorted { $0.name < $1.name }
            .map { (id: $0.identifier, name: $0.name, language: $0.language) }
    }

    // MARK: - Private

    private func buildPhrase(for meeting: MeetingEvent) -> String {
        let template = phraseTemplates.randomElement() ?? phraseTemplates[0]
        return template
            .replacingOccurrences(of: "{name}", with: userName)
            .replacingOccurrences(of: "{minutes}", with: "\(reminderMinutesBefore)")
            .replacingOccurrences(of: "{meeting}", with: meeting.title)
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95 // Slightly slower for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9

        if !selectedVoiceId.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceId)
        } else {
            // Use a good default English voice
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceReminderManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
}
