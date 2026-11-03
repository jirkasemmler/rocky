import Foundation

// MARK: - Exercise

/// Which equipment variant an exercise uses (PRD 6: "varianta (vlastní váha / činky)").
public enum Equipment: String, Codable, Sendable, CaseIterable {
    case bodyweight
    case dumbbells

    /// Czech label for UI.
    public var label: String {
        switch self {
        case .bodyweight: return "Vlastní váha"
        case .dumbbells: return "Činky"
        }
    }
}

/// What the user aims for inside one work interval (PRD 6: "typ (čas / opakování)").
public enum ExerciseTarget: Codable, Sendable, Equatable {
    /// Repetition range, e.g. 12-15 reps.
    case reps(min: Int, max: Int)
    /// Hold for a time range in seconds, e.g. plank 30-45 s.
    case time(minSeconds: Int, maxSeconds: Int)

    public var isTimed: Bool {
        if case .time = self { return true }
        return false
    }
}

public struct Exercise: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    /// Czech display name, e.g. "Dřepy s činkami".
    public var name: String
    /// Short Czech technique tip, spoken optionally before the exercise.
    public var techniqueTip: String
    public var target: ExerciseTarget
    public var equipment: Equipment
    /// True when the target is per side (L/P), e.g. "12 na stranu".
    public var perSide: Bool
    /// True when the user does one side first, then the other: the voice says
    /// "změna strany" halfway through the work interval. False for alternating moves.
    public var switchesSideMidway: Bool

    public init(
        id: String,
        name: String,
        techniqueTip: String,
        target: ExerciseTarget,
        equipment: Equipment,
        perSide: Bool = false,
        switchesSideMidway: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.techniqueTip = techniqueTip
        self.target = target
        self.equipment = equipment
        self.perSide = perSide
        self.switchesSideMidway = switchesSideMidway ?? perSide
    }

    /// Czech human-readable target, e.g. "12–15 opakování", "12 na stranu", "30–45 s".
    public var targetLabel: String {
        let suffixSide = perSide ? " na stranu" : ""
        switch target {
        case let .reps(min, max):
            let range = min == max ? "\(min)" : "\(min)–\(max)"
            return perSide ? "\(range)\(suffixSide)" : "\(range) opakování"
        case let .time(minS, maxS):
            let range = minS == maxS ? "\(minS)" : "\(minS)–\(maxS)"
            return "\(range) s\(suffixSide)"
        }
    }

    /// Target phrased for speech, e.g. "12 až 15 opakování", "30 až 45 sekund".
    public var spokenTargetLabel: String {
        let side = perSide ? " na stranu" : ""
        switch target {
        case let .reps(min, max):
            let range = min == max ? "\(min)" : "\(min) až \(max)"
            return perSide ? "\(range)\(side)" : "\(range) opakování"
        case let .time(minS, maxS):
            let range = minS == maxS ? "\(minS)" : "\(minS) až \(maxS)"
            return "\(range) sekund\(side)"
        }
    }

    public static func == (lhs: Exercise, rhs: Exercise) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.techniqueTip == rhs.techniqueTip
            && lhs.target == rhs.target && lhs.equipment == rhs.equipment && lhs.perSide == rhs.perSide
            && lhs.switchesSideMidway == rhs.switchesSideMidway
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Workout

public enum WorkoutID: String, Codable, Sendable, CaseIterable, Comparable {
    case a = "A"
    case b = "B"
    case c = "C"

    /// Next workout in the A -> B -> C -> A rotation.
    public var next: WorkoutID {
        switch self {
        case .a: return .b
        case .b: return .c
        case .c: return .a
        }
    }

    public static func < (lhs: WorkoutID, rhs: WorkoutID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Interval lengths (seconds) and round count. PRD 3.2 defaults: 40 s work, 20 s rest,
/// 90 s between rounds, 3 rounds; PRD 3.4 warm-up 3 min; stretch is "short" (we use 2 min).
public struct IntervalSettings: Codable, Sendable, Equatable {
    public var workSeconds: Int
    public var restSeconds: Int
    public var roundRestSeconds: Int
    public var rounds: Int
    public var warmUpSeconds: Int
    public var stretchSeconds: Int

    public init(
        workSeconds: Int = 40,
        restSeconds: Int = 20,
        roundRestSeconds: Int = 90,
        rounds: Int = 3,
        warmUpSeconds: Int = 180,
        stretchSeconds: Int = 120
    ) {
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.roundRestSeconds = roundRestSeconds
        self.rounds = rounds
        self.warmUpSeconds = warmUpSeconds
        self.stretchSeconds = stretchSeconds
    }

    public static let `default` = IntervalSettings()

    /// Returns a copy clamped to sane bounds (used before building a plan).
    public func sanitized() -> IntervalSettings {
        IntervalSettings(
            workSeconds: min(max(workSeconds, 5), 600),
            restSeconds: min(max(restSeconds, 0), 600),
            roundRestSeconds: min(max(roundRestSeconds, 0), 900),
            rounds: min(max(rounds, 1), 10),
            warmUpSeconds: min(max(warmUpSeconds, 0), 1800),
            stretchSeconds: min(max(stretchSeconds, 0), 1800)
        )
    }
}

public struct Workout: Codable, Sendable, Equatable, Identifiable {
    public var id: WorkoutID
    /// Czech name, e.g. "Trénink A".
    public var name: String
    public var exercises: [Exercise]
    public var defaultIntervals: IntervalSettings

    public init(id: WorkoutID, name: String, exercises: [Exercise], defaultIntervals: IntervalSettings = .default) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.defaultIntervals = defaultIntervals
    }
}

// MARK: - Weight / difficulty

/// Dumbbell weight used in a session (PRD: 0 / 2 / 5 kg).
public enum DumbbellWeight: Int, Codable, Sendable, CaseIterable, Comparable {
    case none = 0
    case kg2 = 2
    case kg5 = 5

    public var label: String { self == .none ? "Bez činek" : "\(rawValue) kg" }
    public static func < (lhs: DumbbellWeight, rhs: DumbbellWeight) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Subjective difficulty 1 (very easy) ... 5 (very hard).
public struct Difficulty: Codable, Sendable, Equatable, Hashable, Comparable {
    public let value: Int
    public init?(_ value: Int) {
        guard (1...5).contains(value) else { return nil }
        self.value = value
    }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let d = Difficulty(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Difficulty must be 1...5, got \(raw)"))
        }
        self = d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
    public static func < (lhs: Difficulty, rhs: Difficulty) -> Bool { lhs.value < rhs.value }

    public var label: String {
        switch value {
        case 1: return "Velmi lehké"
        case 2: return "Lehké"
        case 3: return "Akorát"
        case 4: return "Těžké"
        default: return "Velmi těžké"
        }
    }
}

// MARK: - Checklist

/// PRD 8a "Checklist". Part of every Session record.
public struct Checklist: Codable, Sendable, Equatable {
    public enum PreItem: String, Codable, Sendable, CaseIterable {
        case water, dumbbells, mat, warmUpDone

        public var label: String {
            switch self {
            case .water: return "Voda"
            case .dumbbells: return "Činky 2 / 5 kg"
            case .mat: return "Podložka"
            case .warmUpDone: return "Rozcvička hotová"
            }
        }
    }

    public enum PostItem: String, Codable, Sendable, CaseIterable {
        case stretchDone, difficultyLogged

        public var label: String {
            switch self {
            case .stretchDone: return "Protažení"
            case .difficultyLogged: return "Zápis náročnosti"
            }
        }
    }

    /// One exercise in one round (1-based round, 0-based exercise index).
    public struct ExerciseCheck: Codable, Sendable, Hashable, Comparable {
        public var round: Int
        public var exerciseIndex: Int
        public init(round: Int, exerciseIndex: Int) {
            self.round = round
            self.exerciseIndex = exerciseIndex
        }
        public static func < (l: ExerciseCheck, r: ExerciseCheck) -> Bool {
            (l.round, l.exerciseIndex) < (r.round, r.exerciseIndex)
        }
    }

    public var pre: Set<PreItem>
    public var exercises: Set<ExerciseCheck>
    public var rounds: Set<Int>
    public var post: Set<PostItem>

    public init(pre: Set<PreItem> = [], exercises: Set<ExerciseCheck> = [], rounds: Set<Int> = [], post: Set<PostItem> = []) {
        self.pre = pre
        self.exercises = exercises
        self.rounds = rounds
        self.post = post
    }

    public var isPreWorkoutComplete: Bool { pre == Set(PreItem.allCases) }

    public mutating func toggle(_ item: PreItem) {
        if pre.contains(item) { pre.remove(item) } else { pre.insert(item) }
    }

    public mutating func toggle(_ item: PostItem) {
        if post.contains(item) { post.remove(item) } else { post.insert(item) }
    }

    public mutating func toggleExercise(round: Int, exerciseIndex: Int) {
        let c = ExerciseCheck(round: round, exerciseIndex: exerciseIndex)
        if exercises.contains(c) { exercises.remove(c) } else { exercises.insert(c) }
    }
}

// MARK: - Timing records

public enum PhaseKind: String, Codable, Sendable, CaseIterable {
    case warmUp, exercise, rest, roundRest, stretch

    public var label: String {
        switch self {
        case .warmUp: return "Rozcvička"
        case .exercise: return "Cvik"
        case .rest: return "Pauza"
        case .roundRest: return "Pauza mezi koly"
        case .stretch: return "Protažení"
        }
    }

    public var isRest: Bool { self == .rest || self == .roundRest }
}

public enum PhaseEndReason: String, Codable, Sendable {
    case completed, skipped, back, aborted
}

/// Actual measured timing of one phase (PRD 8a "Měření timingu").
public struct PhaseTiming: Codable, Sendable, Equatable {
    public var phaseIndex: Int
    public var kind: PhaseKind
    public var round: Int?
    public var exerciseID: String?
    public var plannedSeconds: TimeInterval
    public var startedAt: Date
    public var endedAt: Date
    /// Time spent paused inside this phase.
    public var pausedSeconds: TimeInterval
    public var endReason: PhaseEndReason

    public init(phaseIndex: Int, kind: PhaseKind, round: Int?, exerciseID: String?, plannedSeconds: TimeInterval,
                startedAt: Date, endedAt: Date, pausedSeconds: TimeInterval, endReason: PhaseEndReason) {
        self.phaseIndex = phaseIndex
        self.kind = kind
        self.round = round
        self.exerciseID = exerciseID
        self.plannedSeconds = plannedSeconds
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedSeconds = pausedSeconds
        self.endReason = endReason
    }

    /// Wall-clock duration including pauses.
    public var actualSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    /// Deviation from plan (positive = longer than planned).
    public var deviationSeconds: TimeInterval { actualSeconds - plannedSeconds }
}

// MARK: - Session

public enum SessionKind: String, Codable, Sendable {
    /// Regular planned slot.
    case planned
    /// Catch-up of a missed slot (PRD 8a "Dohánění").
    case catchUp
    /// Easier return after illness/injury.
    case easyReturn
    /// Voluntary workout on a non-training day.
    case bonus
}

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// When the workout started.
    public var date: Date
    public var workoutID: WorkoutID
    public var kind: SessionKind
    public var rounds: Int
    public var weight: DumbbellWeight
    public var difficulty: Difficulty?
    public var note: String
    public var completed: Bool
    public var checklist: Checklist
    public var timings: [PhaseTiming]
    public var plannedSeconds: TimeInterval
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        date: Date,
        workoutID: WorkoutID,
        kind: SessionKind = .planned,
        rounds: Int,
        weight: DumbbellWeight = .kg2,
        difficulty: Difficulty? = nil,
        note: String = "",
        completed: Bool,
        checklist: Checklist = Checklist(),
        timings: [PhaseTiming] = [],
        plannedSeconds: TimeInterval = 0,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.workoutID = workoutID
        self.kind = kind
        self.rounds = rounds
        self.weight = weight
        self.difficulty = difficulty
        self.note = note
        self.completed = completed
        self.checklist = checklist
        self.timings = timings
        self.plannedSeconds = plannedSeconds
        self.finishedAt = finishedAt
    }

    /// Actual wall-clock duration: first phase start to last phase end (or finishedAt).
    public var actualSeconds: TimeInterval {
        if let first = timings.first?.startedAt, let last = timings.map(\.endedAt).max() {
            return last.timeIntervalSince(first)
        }
        if let finishedAt { return finishedAt.timeIntervalSince(date) }
        return 0
    }
}

// MARK: - Settings

/// Weekday using Foundation's Calendar numbering (1 = Sunday ... 7 = Saturday).
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public var shortLabel: String {
        switch self {
        case .monday: return "Po"
        case .tuesday: return "Út"
        case .wednesday: return "St"
        case .thursday: return "Čt"
        case .friday: return "Pá"
        case .saturday: return "So"
        case .sunday: return "Ne"
        }
    }

    public var label: String {
        switch self {
        case .monday: return "Pondělí"
        case .tuesday: return "Úterý"
        case .wednesday: return "Středa"
        case .thursday: return "Čtvrtek"
        case .friday: return "Pátek"
        case .saturday: return "Sobota"
        case .sunday: return "Neděle"
        }
    }

    /// Monday-first ordering for Czech UI.
    public static var mondayFirst: [Weekday] { [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday] }

    public static func < (l: Weekday, r: Weekday) -> Bool {
        mondayFirst.firstIndex(of: l)! < mondayFirst.firstIndex(of: r)!
    }
}

/// Simple hour:minute time of day.
public struct TimeOfDay: Codable, Sendable, Equatable, Comparable, Hashable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
    public var minutesSinceMidnight: Int { hour * 60 + minute }
    public static func < (l: TimeOfDay, r: TimeOfDay) -> Bool { l.minutesSinceMidnight < r.minutesSinceMidnight }
    public var label: String { String(format: "%d:%02d", hour, minute) }
}

public struct Settings: Codable, Sendable, Equatable {
    /// Training weekdays (PRD 8a: 3 slots per week, e.g. Mon/Wed/Fri).
    public var trainingDays: Set<Weekday>
    /// Evening reminder time.
    public var reminderTime: TimeOfDay
    /// Latest time an escalating reminder may fire (open question, proposed 22:30).
    public var latestEscalation: TimeOfDay
    public var intervals: IntervalSettings
    public var voiceEnabled: Bool
    /// 0.0 ... 1.0
    public var volume: Double
    public var vibrationEnabled: Bool
    public var techniqueTipsEnabled: Bool
    /// AVSpeechSynthesisVoice identifier; nil = default Czech voice (proposed: Zuzana).
    public var voiceIdentifier: String?
    /// AVSpeechUtterance rate (0.0 ... 1.0; system default is 0.5).
    public var speechRate: Double
    /// Play voice on the watch speaker (otherwise watch = haptics only).
    public var watchSoundEnabled: Bool
    /// Also escalate reminders on regular (non catch-up) days.
    public var escalateOnPlannedDays: Bool

    public init(
        trainingDays: Set<Weekday> = [.monday, .wednesday, .friday],
        reminderTime: TimeOfDay = TimeOfDay(hour: 19, minute: 0),
        latestEscalation: TimeOfDay = TimeOfDay(hour: 22, minute: 30),
        intervals: IntervalSettings = .default,
        voiceEnabled: Bool = true,
        volume: Double = 1.0,
        vibrationEnabled: Bool = true,
        techniqueTipsEnabled: Bool = true,
        voiceIdentifier: String? = nil,
        speechRate: Double = 0.5,
        watchSoundEnabled: Bool = false,
        escalateOnPlannedDays: Bool = false
    ) {
        self.trainingDays = trainingDays
        self.reminderTime = reminderTime
        self.latestEscalation = latestEscalation
        self.intervals = intervals
        self.voiceEnabled = voiceEnabled
        self.volume = volume
        self.vibrationEnabled = vibrationEnabled
        self.techniqueTipsEnabled = techniqueTipsEnabled
        self.voiceIdentifier = voiceIdentifier
        self.speechRate = speechRate
        self.watchSoundEnabled = watchSoundEnabled
        self.escalateOnPlannedDays = escalateOnPlannedDays
    }

    public static let `default` = Settings()
}

// MARK: - Postponement

/// Reason required to postpone a due workout (PRD 8a: nemoc, zranění, cestování).
public enum PostponeReason: String, Codable, Sendable, CaseIterable {
    case illness, injury, travel

    public var label: String {
        switch self {
        case .illness: return "Nemoc"
        case .injury: return "Zranění"
        case .travel: return "Cestování"
        }
    }

    /// Illness/injury clear debt and plan an easier return.
    public var clearsDebt: Bool { self != .travel }
}

public struct Postponement: Codable, Sendable, Equatable {
    /// Any instant within the postponed day.
    public var date: Date
    public var reason: PostponeReason
    public init(date: Date, reason: PostponeReason) {
        self.date = date
        self.reason = reason
    }
}
