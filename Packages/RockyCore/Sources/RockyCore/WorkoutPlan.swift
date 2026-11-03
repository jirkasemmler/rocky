import Foundation

/// One step of a workout timeline.
public struct Phase: Sendable, Equatable {
    public var index: Int
    public var kind: PhaseKind
    /// Planned duration in seconds.
    public var duration: TimeInterval
    /// 1-based round for exercise/rest/roundRest phases, nil for warm-up and stretch.
    public var round: Int?
    /// 0-based index into `Workout.exercises` for exercise phases.
    public var exerciseIndex: Int?
    /// The exercise performed in this phase (exercise phases only).
    public var exercise: Exercise?
    /// The next exercise the user will do after this phase, if any.
    public var upcomingExercise: Exercise?

    public init(index: Int, kind: PhaseKind, duration: TimeInterval, round: Int? = nil, exerciseIndex: Int? = nil,
                exercise: Exercise? = nil, upcomingExercise: Exercise? = nil) {
        self.index = index
        self.kind = kind
        self.duration = duration
        self.round = round
        self.exerciseIndex = exerciseIndex
        self.exercise = exercise
        self.upcomingExercise = upcomingExercise
    }
}

/// Immutable, fully expanded timeline of a workout:
/// warm-up -> (exercise, rest)* per round with a between-rounds rest -> stretch.
public struct WorkoutPlan: Sendable, Equatable {
    public let workout: Workout
    public let intervals: IntervalSettings
    public let phases: [Phase]

    public var rounds: Int { intervals.rounds }

    public init(workout: Workout, intervals: IntervalSettings? = nil, roundsOverride: Int? = nil) {
        var iv = (intervals ?? workout.defaultIntervals).sanitized()
        if let roundsOverride { iv.rounds = min(max(roundsOverride, 1), 10) }
        self.workout = workout
        self.intervals = iv
        self.phases = WorkoutPlan.buildPhases(workout: workout, intervals: iv)
    }

    /// Planned total duration in seconds.
    public var plannedDuration: TimeInterval { phases.reduce(0) { $0 + $1.duration } }

    /// Planned start offset of each phase from the workout start.
    public var plannedOffsets: [TimeInterval] {
        var acc: TimeInterval = 0
        return phases.map { p in
            defer { acc += p.duration }
            return acc
        }
    }

    public var exercisePhaseIndices: [Int] { phases.filter { $0.kind == .exercise }.map(\.index) }

    private static func buildPhases(workout: Workout, intervals iv: IntervalSettings) -> [Phase] {
        struct Draft { var kind: PhaseKind; var duration: Int; var round: Int?; var exerciseIndex: Int? }
        var drafts: [Draft] = []
        if iv.warmUpSeconds > 0 {
            drafts.append(Draft(kind: .warmUp, duration: iv.warmUpSeconds, round: nil, exerciseIndex: nil))
        }
        let n = workout.exercises.count
        if n > 0 {
            for round in 1...iv.rounds {
                for i in 0..<n {
                    drafts.append(Draft(kind: .exercise, duration: iv.workSeconds, round: round, exerciseIndex: i))
                    let lastInRound = i == n - 1
                    if !lastInRound {
                        if iv.restSeconds > 0 {
                            drafts.append(Draft(kind: .rest, duration: iv.restSeconds, round: round, exerciseIndex: nil))
                        }
                    } else if round < iv.rounds, iv.roundRestSeconds > 0 {
                        drafts.append(Draft(kind: .roundRest, duration: iv.roundRestSeconds, round: round, exerciseIndex: nil))
                    }
                }
            }
        }
        // Fixed 2-minute stretch closes every workout (also the shortened version).
        drafts.append(Draft(kind: .stretch, duration: IntervalSettings.stretchSeconds, round: nil, exerciseIndex: nil))

        var phases: [Phase] = []
        phases.reserveCapacity(drafts.count)
        for (idx, d) in drafts.enumerated() {
            let exercise = d.exerciseIndex.map { workout.exercises[$0] }
            let upcoming = drafts[(idx + 1)...].first(where: { $0.kind == .exercise })
                .flatMap { $0.exerciseIndex }
                .map { workout.exercises[$0] }
            phases.append(Phase(index: idx, kind: d.kind, duration: TimeInterval(d.duration), round: d.round,
                                exerciseIndex: d.exerciseIndex, exercise: exercise, upcomingExercise: upcoming))
        }
        return phases
    }
}
