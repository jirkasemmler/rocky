import Foundation
import Observation
import TrainingCore

/// Drives one running workout on either device: ticks `WorkoutRunner`, forwards cues to
/// speech + haptics, mirrors commands to the other device and exposes a snapshot for the UI.
///
/// Timing comes from timestamps inside `WorkoutEngine`, so a late tick (background, locked
/// screen) never drifts: the next tick catches up and stale cues are dropped.
@MainActor
@Observable
final class WorkoutController {
    enum Stage: Equatable {
        case idle
        case running
        case summary(completed: Bool)
    }

    private(set) var stage: Stage = .idle
    private(set) var snapshot: EngineSnapshot?
    private(set) var plan: WorkoutPlan?
    private(set) var checklist = Checklist()
    private(set) var sessionID = UUID()
    private(set) var kind: SessionKind = .planned
    /// Last spoken cue, shown as a subtitle (also useful with voice off).
    private(set) var lastCueText = ""
    var weight: DumbbellWeight = .kg2

    let origin: SyncMessage.Origin
    @ObservationIgnored private var runner: WorkoutRunner?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var cueConfig = VoiceCueConfig()
    @ObservationIgnored let speech: SpeechSpeaking?
    @ObservationIgnored let haptics: HapticsPlaying?
    @ObservationIgnored let audio: AudioSessionControlling?
    @ObservationIgnored let sync: WatchSyncing?

    /// Platform hooks (watch: HKWorkoutSession start/pause/end).
    @ObservationIgnored var onStarted: ((Date) -> Void)?
    @ObservationIgnored var onPauseChanged: ((_ paused: Bool, _ at: Date) -> Void)?
    @ObservationIgnored var onEnded: ((_ at: Date, _ completed: Bool) -> Void)?

    init(origin: SyncMessage.Origin, speech: SpeechSpeaking?, haptics: HapticsPlaying?, audio: AudioSessionControlling?,
         sync: WatchSyncing?) {
        self.origin = origin
        self.speech = speech
        self.haptics = haptics
        self.audio = audio
        self.sync = sync
        audio?.onInterruption = { [weak self] began in
            // Phone call etc.: pause, user resumes manually.
            if began, self?.snapshot?.status == .running { self?.perform(.pause) }
        }
    }

    var isRunning: Bool { stage == .running }
    var isPaused: Bool { snapshot?.status == .paused }

    func apply(settings: Settings, speechEnabled: Bool? = nil) {
        speech?.isEnabled = speechEnabled ?? settings.voiceEnabled
        speech?.voiceIdentifier = settings.voiceIdentifier
        speech?.rate = settings.speechRate
        speech?.volume = settings.volume
        haptics?.isEnabled = settings.vibrationEnabled
        cueConfig.techniqueTipsEnabled = settings.techniqueTipsEnabled
    }

    // MARK: Lifecycle

    func start(workoutID: WorkoutID, intervals: IntervalSettings, roundsOverride: Int?, kind: SessionKind,
               weight: DumbbellWeight, pre: Set<Checklist.PreItem>, sessionID: UUID = UUID(), startedAt: Date? = nil,
               broadcast: Bool = true) {
        stopTicking()
        let plan = WorkoutPlan(workout: WorkoutLibrary.workout(workoutID), intervals: intervals, roundsOverride: roundsOverride)
        let runner = WorkoutRunner(plan: plan, cueConfig: cueConfig, checklist: Checklist(pre: pre))
        self.plan = plan
        self.runner = runner
        self.sessionID = sessionID
        self.kind = kind
        self.weight = weight
        self.lastCueText = ""
        stage = .running

        audio?.beginWorkout()
        let output = startedAt.map { runner.start(at: $0) } ?? runner.start()
        let actualStart = runner.engine.startedAt ?? Date()
        onStarted?(actualStart)
        if broadcast {
            sync?.send(.workoutStarted(sessionID: sessionID, workoutID: workoutID, intervals: plan.intervals,
                                       rounds: plan.rounds, kind: kind, startedAt: actualStart, origin: origin))
        }
        handle(output)
        startTicking()
    }

    func perform(_ command: SyncMessage.Command, broadcast: Bool = true) {
        guard let runner, stage == .running else { return }
        let output: WorkoutRunner.Output
        switch command {
        case .pause: output = runner.pause()
        case .resume: output = runner.resume()
        case .skip: output = runner.skip()
        case .back: output = runner.back()
        case .abort: output = runner.abort()
        }
        if broadcast {
            sync?.send(.command(sessionID: sessionID, command: command, at: Date(), origin: origin))
        }
        handle(output)
    }

    func togglePause() { perform(isPaused ? .resume : .pause) }

    /// Call when the app returns to the foreground.
    func tick() {
        guard let runner, stage == .running else { return }
        handle(runner.tick())
    }

    /// Mirrors the other device (start / pause / skip / back / abort).
    func handleRemote(_ message: SyncMessage) {
        switch message {
        case let .workoutStarted(id, workoutID, intervals, rounds, kind, startedAt, from) where from != origin:
            guard stage != .running else { return }
            start(workoutID: workoutID, intervals: intervals, roundsOverride: rounds, kind: kind, weight: weight,
                  pre: [], sessionID: id, startedAt: startedAt, broadcast: false)
        case let .command(id, command, at, from) where from != origin && id == sessionID:
            guard let runner, stage == .running else { return }
            handle(runner.apply(command, at: at))
        default:
            break
        }
    }

    // MARK: Checklist

    func toggle(_ item: Checklist.PreItem) { runner?.toggle(item); refreshChecklist() }
    func toggle(_ item: Checklist.PostItem) { runner?.toggle(item); refreshChecklist() }
    func toggleExercise(round: Int, exerciseIndex: Int) {
        runner?.toggleExercise(round: round, exerciseIndex: exerciseIndex)
        refreshChecklist()
    }

    // MARK: Summary

    func makeSession(difficulty: Difficulty?, note: String) -> Session? {
        runner?.makeSession(id: sessionID, kind: kind, weight: weight, difficulty: difficulty, note: note)
    }

    /// Sends a saved session to the other device (queued if it is not reachable).
    func publish(_ session: Session) {
        sync?.send(.sessionSaved(session, origin: origin))
    }

    func reset() {
        stopTicking()
        runner = nil
        plan = nil
        snapshot = nil
        checklist = Checklist()
        stage = .idle
    }

    // MARK: Private

    private func handle(_ output: WorkoutRunner.Output) {
        for cue in output.cues {
            if let pattern = cue.haptic { haptics?.play(pattern) }
            let interruptible = cue.kind == .techniqueTip || cue.kind == .announceNext
            speech?.speak(cue.text, interruptible: interruptible)
            lastCueText = cue.text
        }
        for event in output.events {
            switch event {
            case let .paused(at): onPauseChanged?(true, at)
            case let .resumed(at): onPauseChanged?(false, at)
            case let .finished(at): finish(at: at, completed: true)
            case let .aborted(at): finish(at: at, completed: false)
            default: break
            }
        }
        snapshot = runner?.snapshot
        refreshChecklist()
    }

    private func refreshChecklist() {
        if let runner { checklist = runner.checklist }
    }

    private func finish(at date: Date, completed: Bool) {
        stopTicking()
        stage = .summary(completed: completed)
        onEnded?(date, completed)
        // Let the final "Konec tréninku" cue finish before releasing the audio session.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.stage != .running else { return }
            self.audio?.endWorkout()
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
