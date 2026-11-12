import Foundation
import Observation
import RockyCore

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
    /// Active catalog of this device (workouts for remote starts without a definition, cue texts).
    @ObservationIgnored var catalogProvider: () -> Catalog = { .builtIn }
    @ObservationIgnored private var rockyLinesEnabled = true
    @ObservationIgnored private var address = ""
    @ObservationIgnored let speech: SpeechSpeaking?
    @ObservationIgnored let haptics: HapticsPlaying?
    @ObservationIgnored let audio: AudioSessionControlling?
    @ObservationIgnored let sync: WatchSyncing?

    /// Platform hooks (watch: HKWorkoutSession start/pause/end).
    /// `local` = started on this device (false = mirrored from the other one).
    @ObservationIgnored var onStarted: ((_ at: Date, _ local: Bool) -> Void)?
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
    /// "Hotovo" is offered on exercises (and warm-up / stretch), not on rests.
    var canFinishEarly: Bool { runner?.engine.canFinishEarly ?? false }

    /// Whole-workout progress 0...1 by planned time: done phases count fully (also when skipped
    /// or finished early), the current one by its elapsed part.
    var overallProgress: Double {
        guard let plan, let snapshot, plan.plannedDuration > 0 else { return 0 }
        if snapshot.status == .finished { return 1 }
        return min(1, max(0, 1 - snapshot.plannedRemaining / plan.plannedDuration))
    }

    func apply(settings: Settings, speechEnabled: Bool? = nil) {
        speech?.isEnabled = speechEnabled ?? settings.voiceEnabled
        speech?.voiceIdentifier = settings.voiceIdentifier
        speech?.rate = settings.speechRate
        speech?.volume = settings.volume
        haptics?.isEnabled = settings.vibrationEnabled
        cueConfig.techniqueTipsEnabled = settings.techniqueTipsEnabled
        rockyLinesEnabled = settings.rockyLinesEnabled
        address = settings.address
    }

    /// "Rockyho hlášky" for this session. Seeded from the session ID, so a mirrored workout
    /// picks the same lines on iPhone and Watch, yet every workout sounds a bit different.
    private func rockyLinesConfig(sessionID: UUID, kind: SessionKind, roundsOverride: Int?) -> RockyLinesConfig? {
        guard rockyLinesEnabled else { return nil }
        let opening: RockyLinesConfig.Opening
        if roundsOverride != nil {
            opening = .shortened
        } else if kind == .catchUp {
            opening = .catchUp
        } else {
            opening = .normal
        }
        let seed = withUnsafeBytes(of: sessionID.uuid) { raw in
            raw.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        return RockyLinesConfig(seed: seed, address: address, opening: opening)
    }

    // MARK: Lifecycle

    /// - Parameter definition: exact workout to run; nil = the active catalog's workout `workoutID`.
    func start(workoutID: WorkoutID, intervals: IntervalSettings, roundsOverride: Int?, kind: SessionKind,
               weight: DumbbellWeight, pre: Set<Checklist.PreItem>, sessionID: UUID = UUID(), startedAt: Date? = nil,
               broadcast: Bool = true, definition: Workout? = nil) {
        stopTicking()
        let catalog = catalogProvider()
        let workout = definition ?? catalog.workout(workoutID)
        let plan = WorkoutPlan(workout: workout, intervals: intervals, roundsOverride: roundsOverride)
        var config = cueConfig
        config.warmUpDescription = catalog.warmUpDescription
        config.stretchDescription = catalog.stretchDescription
        config.rockyLines = rockyLinesConfig(sessionID: sessionID, kind: kind, roundsOverride: roundsOverride)
        let runner = WorkoutRunner(plan: plan, cueConfig: config, checklist: Checklist(pre: pre))
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
        onStarted?(actualStart, broadcast)
        if broadcast {
            sync?.send(.workoutStarted(sessionID: sessionID, workoutID: workoutID, intervals: plan.intervals,
                                       rounds: plan.rounds, kind: kind, startedAt: actualStart, origin: origin,
                                       workout: plan.workout))
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
        case .done: output = runner.finishEarly()
        }
        if broadcast {
            sync?.send(.command(sessionID: sessionID, command: command, at: Date(), origin: origin))
        }
        handle(output)
    }

    func togglePause() { perform(isPaused ? .resume : .pause) }

    /// Re-sends the start of the running workout (e.g. after the phone launched the watch app,
    /// whose WCSession was not reachable at the original start). The other side ignores it if
    /// it already runs a workout.
    /// Returns false when there is nothing to send (no running workout).
    @discardableResult
    func rebroadcastStart() -> Bool {
        guard stage == .running, let plan, let startedAt = runner?.engine.startedAt else { return false }
        sync?.send(.workoutStarted(sessionID: sessionID, workoutID: plan.workout.id, intervals: plan.intervals,
                                   rounds: plan.rounds, kind: kind, startedAt: startedAt, origin: origin,
                                   workout: plan.workout))
        return true
    }

    /// The other device discarded the same workout: leave the summary here too (without saving).
    func otherDeviceDiscarded(sessionID id: UUID) {
        guard id == sessionID, case .summary = stage else { return }
        reset()
    }

    /// Discards the finished workout here and tells the other device.
    func discard() {
        sync?.send(.sessionDiscarded(sessionID: sessionID, origin: origin))
        reset()
    }

    /// The other device saved the same workout: leave the summary here too.
    func otherDeviceSaved(_ session: Session) {
        guard session.id == sessionID, case .summary = stage else { return }
        reset()
    }

    /// Call when the app returns to the foreground.
    func tick() {
        guard let runner, stage == .running else { return }
        handle(runner.tick())
    }

    /// Mirrors the other device (start / pause / skip / back / abort).
    func handleRemote(_ message: SyncMessage) {
        switch message {
        case let .workoutStarted(id, workoutID, intervals, rounds, kind, startedAt, from, definition) where from != origin:
            // Only when idle (never over a running workout or an unsaved summary), and never the
            // same session again: the phone re-sends the start, and a late duplicate must not
            // restart a workout that already ended here.
            guard stage == .idle, id != sessionID else { return }
            // `rounds` is the plan's total; only a value different from the intervals is an override
            // (shortened version). Passing it unconditionally made every mirrored workout "shortened".
            let override = rounds == intervals.rounds ? nil : rounds
            start(workoutID: workoutID, intervals: intervals, roundsOverride: override, kind: kind, weight: weight,
                  pre: [], sessionID: id, startedAt: startedAt, broadcast: false, definition: definition)
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
            let interruptible = cue.kind == .techniqueTip || cue.kind == .announceNext || cue.kind == .flavor
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
