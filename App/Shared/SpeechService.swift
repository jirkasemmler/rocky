import AVFoundation

/// Speaks Czech voice cues (PRD 8a). Uses the system cs-CZ voices; default female "Zuzana".
@MainActor
protocol SpeechSpeaking: AnyObject {
    var isEnabled: Bool { get set }
    var voiceIdentifier: String? { get set }
    /// 0...1, mapped onto AVSpeechUtterance min...max rate.
    var rate: Double { get set }
    var volume: Double { get set }
    /// `interruptible` utterances (technique tips, announcements) are cut off when a
    /// time-critical cue (countdown, start, rest) arrives.
    func speak(_ text: String, interruptible: Bool)
    func stop()
}

struct CzechVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let quality: String
}

@MainActor
final class SpeechService: NSObject, SpeechSpeaking {
    static let language = "cs-CZ"

    var isEnabled = true
    var voiceIdentifier: String?
    var rate: Double = 0.5
    var volume: Double = 1.0

    private let synthesizer = AVSpeechSynthesizer()
    private let audio: AudioSessionControlling?
    private var currentIsInterruptible = false

    init(audio: AudioSessionControlling?) {
        self.audio = audio
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
    }

    func speak(_ text: String, interruptible: Bool) {
        guard isEnabled, !text.isEmpty else { return }
        if synthesizer.isSpeaking, currentIsInterruptible, !interruptible {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audio?.beginSpeech()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(identifier: voiceIdentifier)
        let r = Float(min(max(rate, 0), 1))
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * r
        utterance.volume = Float(min(max(volume, 0), 1))
        utterance.prefersAssistiveTechnologySettings = false
        currentIsInterruptible = interruptible
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Speaks a short sample in the given voice (Settings → "Přehrát ukázku").
    func preview(identifier: String?) {
        let saved = voiceIdentifier
        voiceIdentifier = identifier
        speak("Dřep. Dvanáct až patnáct opakování. Tři, dva, jedna.", interruptible: true)
        voiceIdentifier = saved
    }

    static func czechVoices() -> [CzechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .map { voice in
                let quality: String
                switch voice.quality {
                case .premium: quality = "Prémiový"
                case .enhanced: quality = "Vylepšený"
                default: quality = "Standardní"
                }
                return CzechVoice(id: voice.identifier, name: voice.name, quality: quality)
            }
            .sorted { $0.name < $1.name }
    }

    /// Explicit identifier, else the best installed "Zuzana", else any cs-CZ voice.
    static func voice(identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let czech = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        let zuzana = czech.filter { $0.name.localizedCaseInsensitiveContains("Zuzana") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        return zuzana ?? czech.first ?? AVSpeechSynthesisVoice(language: language)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedUtterance() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedUtterance() }
    }

    private func finishedUtterance() {
        if !synthesizer.isSpeaking {
            currentIsInterruptible = false
            audio?.endSpeech()
        }
    }
}
