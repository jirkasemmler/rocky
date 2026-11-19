import Foundation

/// Live state of a running workout, replicated between iPhone and Apple Watch. Each device sends
/// its full state after every action and periodically; the receiver adopts it if it
/// `supersedes` its own. Lost messages heal with the next state; two workouts started
/// independently on both devices converge on the earlier one (D-27).
public struct LiveWorkout: Codable, Sendable, Equatable {
    public var sessionID: UUID
    /// Incremented by every action on either device; the receiver takes over the revision.
    public var revision: Int
    public var workout: Workout
    public var intervals: IntervalSettings
    public var rounds: Int
    public var kind: SessionKind
    public var origin: SyncMessage.Origin
    public var engine: EngineState

    public init(sessionID: UUID, revision: Int, workout: Workout, intervals: IntervalSettings, rounds: Int,
                kind: SessionKind, origin: SyncMessage.Origin, engine: EngineState) {
        self.sessionID = sessionID
        self.revision = revision
        self.workout = workout
        self.intervals = intervals
        self.rounds = rounds
        self.kind = kind
        self.origin = origin
        self.engine = engine
    }

    /// Rounds override as used to build the plan (only a value different from the intervals).
    public var roundsOverride: Int? { rounds == intervals.rounds ? nil : rounds }

    public var plan: WorkoutPlan { WorkoutPlan(workout: workout, intervals: intervals, roundsOverride: roundsOverride) }

    /// Deterministic on both devices:
    /// - same session: higher revision wins; on a tie the phone's state wins;
    /// - different sessions (started independently): the earlier start wins; ties by origin
    ///   (phone) and then by session ID.
    public func supersedes(_ other: LiveWorkout) -> Bool {
        if sessionID == other.sessionID {
            if revision != other.revision { return revision > other.revision }
            return origin == .phone && other.origin == .watch
        }
        let mine = engine.startedAt ?? .distantFuture
        let theirs = other.engine.startedAt ?? .distantFuture
        if mine != theirs { return mine < theirs }
        if origin != other.origin { return origin == .phone }
        return sessionID.uuidString < other.sessionID.uuidString
    }

    /// Worth joining from idle: still running or paused and not long past its planned end (a late
    /// application context must not resurrect an old workout).
    public func isJoinable(at now: Date) -> Bool {
        guard engine.status == .running || engine.status == .paused, let started = engine.startedAt else { return false }
        return now.timeIntervalSince(started) < plan.plannedDuration + 30 * 60
    }
}
