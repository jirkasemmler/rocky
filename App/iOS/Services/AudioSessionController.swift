import AVFoundation

/// Owns the AVAudioSession during a workout (PRD 8a: voice must keep working with the screen
/// locked and over music from other apps).
///
/// - During a workout the session is `.playback` / `.voicePrompt` with `.mixWithOthers`, so the
///   user's music keeps playing.
/// - While a cue is spoken we add `.duckOthers` (music gets quieter) and remove it afterwards.
/// - A silent `AVAudioEngine` loop keeps the app alive in the background (Background Modes →
///   Audio) so cue timing keeps working with the screen locked.
///
/// UNVERIFIED on device: whether removing `.duckOthers` un-ducks other audio without
/// deactivating the session while the keep-alive engine runs. Fallback documented in
/// docs/DECISIONS.md (D-15).
@MainActor
final class AudioSessionController: AudioSessionControlling {
    var onInterruption: ((_ began: Bool) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isWorkoutActive = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated {
                self?.onInterruption?(began)
            }
        }
    }

    func beginWorkout() {
        guard !isWorkoutActive else { return }
        isWorkoutActive = true
        configure(duck: false)
        startKeepAlive()
    }

    func endWorkout() {
        guard isWorkoutActive else { return }
        isWorkoutActive = false
        player.stop()
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginSpeech() { configure(duck: true) }

    func endSpeech() {
        if isWorkoutActive {
            configure(duck: false)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func configure(duck: Bool) {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if duck { options.insert(.duckOthers) }
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: options)
            try session.setActive(true)
        } catch {
            // Non-fatal: the visual timer and haptics still work.
        }
    }

    private func startKeepAlive() {
        guard !engine.isRunning,
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let samples = buffer.floatChannelData?[0] {
            samples.update(repeating: 0, count: Int(buffer.frameLength))
        }
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            // Without keep-alive the timer still recovers from timestamps when the app returns.
        }
    }
}
