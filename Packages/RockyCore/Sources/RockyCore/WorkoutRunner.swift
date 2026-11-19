import Foundation

/// Glue between `WorkoutEngine`, an injected `TimeSource` and `VoiceCueScheduler`.
///
/// The app calls `tick()` frequently (e.g. every 100 ms, and whenever it returns from the
/// background) and forwards the returned cues to speech/haptics. Not thread-safe: use it from
/// one actor (the app uses the main actor).
public final class WorkoutRunner {
    public struct Output: Sendable, Equatable {
        public var events: [EngineEvent]
        public var cues: [VoiceCue]
        public static let empty = Output(events: [], cues: [])
    }

    public private(set) var engine: WorkoutEngine
    public let cueScheduler: VoiceCueScheduler
    public let timeSource: TimeSource
    /// Cues older than this (e.g. after the app was suspended) are dropped instead of spoken late.
    public var staleCueTolerance: TimeInterval = 1.5
    public private(set) var checklist: Checklist

    private var cursorPhase: Int = -1
    private var cursorElapsed: TimeInterval = -1
    private var workoutEndDelivered = false

    public init(plan: WorkoutPlan, cueConfig: VoiceCueConfig = VoiceCueConfig(), timeSource: TimeSource = SystemTimeSource(),
                checklist: Checklist = Checklist()) {
        self.engine = WorkoutEngine(plan: plan)
        self.cueScheduler = VoiceCueScheduler(plan: plan, config: cueConfig)
        self.timeSource = timeSource
        self.checklist = checklist
    }

    public var plan: WorkoutPlan { engine.plan }
    public var snapshot: EngineSnapshot { engine.snapshot(at: timeSource.now()) }

    // MARK: Commands

    @discardableResult public func start() -> Output { run { $0.start(at: $1) } }
    @discardableResult public func tick() -> Output { run { $0.update(at: $1) } }
    @discardableResult public func pause() -> Output { run { $0.pause(at: $1) } }
    @discardableResult public func resume() -> Output { run { $0.resume(at: $1) } }
    @discardableResult public func togglePause() -> Output { run { $0.togglePause(at: $1) } }
    @discardableResult public func skip() -> Output { run { $0.skip(at: $1) } }
    @discardableResult public func back() -> Output { run { $0.back(at: $1) } }
    /// "Hotovo": finish the current exercise early.
    @discardableResult public func finishEarly() -> Output { run { $0.finishEarly(at: $1) } }
    @discardableResult public func abort() -> Output { run { $0.abort(at: $1) } }

    /// Starts at an explicit (possibly past) time, e.g. when the other device started the workout.
    @discardableResult public func start(at date: Date) -> Output { run { engine, now in engine.start(at: date) + engine.update(at: now) } }
    /// Applies a command received from the other device at its original timestamp.
    @discardableResult public func apply(_ command: SyncMessage.Command, at date: Date) -> Output {
        run { engine, now in engine.apply(command, at: min(date, now)) + engine.update(at: now) }
    }

    /// Takes over the other device's engine state (live sync). Reports the transitions as events
    /// (phase change, pause/resume, finished/aborted) so the app reacts as for a local command;
    /// cues of a newly entered phase are still spoken if they are not stale.
    @discardableResult public func adopt(_ state: EngineState) -> Output {
        let before = engine
        let now = timeSource.now()
        engine = WorkoutEngine(plan: plan, state: state)
        var events: [EngineEvent] = []
        if before.status != .running && before.status != .paused && engine.isActive, let started = engine.startedAt {
            events.append(.started(at: started))
        }
        if engine.phaseIndex != before.phaseIndex || before.status == .idle, engine.isActive,
           let phase = engine.currentPhase {
            events.append(.phaseStarted(phase, at: state.phaseStartedAt))
            cursorPhase = phase.index
            cursorElapsed = -1
        }
        switch (before.status, engine.status) {
        case (.running, .paused): events.append(.paused(at: state.pausedAt ?? now))
        case (.paused, .running): events.append(.resumed(at: now))
        default: break
        }
        if engine.status == .finished, before.status != .finished { events.append(.finished(at: state.endedAt ?? now)) }
        if engine.status == .aborted, before.status != .aborted { events.append(.aborted(at: state.endedAt ?? now)) }
        return run(prefilled: events) { _, _ in [] }
    }

    // MARK: Checklist

    public func toggle(_ item: Checklist.PreItem) { checklist.toggle(item) }
    public func toggle(_ item: Checklist.PostItem) { checklist.toggle(item) }
    public func toggleExercise(round: Int, exerciseIndex: Int) { checklist.toggleExercise(round: round, exerciseIndex: exerciseIndex) }

    /// Builds the session record once the workout finished (or was aborted).
    public func makeSession(id: UUID = UUID(), kind: SessionKind, weight: DumbbellWeight, difficulty: Difficulty?,
                            note: String) -> Session {
        var list = checklist
        if difficulty != nil { list.post.insert(.difficultyLogged) }
        return Session(
            id: id,
            date: engine.startedAt ?? timeSource.now(),
            workoutID: plan.workout.id,
            kind: kind,
            rounds: plan.rounds,
            weight: weight,
            difficulty: difficulty,
            note: note,
            completed: engine.status == .finished,
            checklist: list,
            timings: engine.timings,
            plannedSeconds: plan.plannedDuration,
            finishedAt: engine.endedAt,
            workout: plan.workout
        )
    }

    // MARK: Private

    private func run(prefilled: [EngineEvent] = [], _ body: (inout WorkoutEngine, Date) -> [EngineEvent]) -> Output {
        let now = timeSource.now()
        let events = prefilled + body(&engine, now)
        var cues: [VoiceCue] = []

        for event in events {
            switch event {
            case let .phaseEnded(t):
                if t.endReason == .completed, t.phaseIndex == cursorPhase {
                    // Deliver the remainder of the phase (e.g. the last countdown word / workout end).
                    let pending = cueScheduler.cues(forPhase: t.phaseIndex, from: cursorElapsed, through: t.plannedSeconds)
                    let phaseBoundary = t.endedAt
                    cues += pending.filter { cue in
                        let fireAt = phaseBoundary - (t.plannedSeconds - cue.offset)
                        return now.timeIntervalSince(fireAt) <= staleCueTolerance || cue.kind == .workoutEnd
                    }
                }
                cursorElapsed = .infinity
            case let .phaseStarted(phase, _):
                cursorPhase = phase.index
                cursorElapsed = -1
            case .finished:
                if !workoutEndDelivered, !cues.contains(where: { $0.kind == .workoutEnd }),
                   let endCue = cueScheduler.allCues.last(where: { $0.kind == .workoutEnd }) {
                    cues.append(endCue)
                }
            default:
                break
            }
        }

        if engine.isActive, engine.phaseIndex == cursorPhase {
            let elapsed = engine.elapsedInPhase(at: now)
            if elapsed > cursorElapsed {
                let due = cueScheduler.cues(forPhase: cursorPhase, from: cursorElapsed, through: elapsed)
                cues += due.filter { elapsed - $0.offset <= staleCueTolerance }
                cursorElapsed = elapsed
            }
        }

        if cues.contains(where: { $0.kind == .workoutEnd }) { workoutEndDelivered = true }
        updateChecklist()
        return Output(events: events, cues: cues)
    }

    private func updateChecklist() {
        checklist.exercises.formUnion(engine.completedExerciseChecks)
        checklist.rounds.formUnion(engine.completedRounds)
        if engine.didComplete(.warmUp) { checklist.pre.insert(.warmUpDone) }
        if engine.didComplete(.stretch) { checklist.post.insert(.stretchDone) }
    }
}
