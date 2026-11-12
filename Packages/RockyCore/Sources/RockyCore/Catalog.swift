import Foundation

/// The exercise catalog: exercises, the composition of workouts A/B/C and the warm-up / stretch
/// texts. Managed on the Rocky server (docs/SERVER-SPEC.md §4.1); the built-in `WorkoutLibrary`
/// is revision 0 and the fallback when no server catalog is cached.
public struct Catalog: Codable, Sendable, Equatable {
    public struct WorkoutEntry: Codable, Sendable, Equatable {
        public var id: WorkoutID
        public var name: String
        public var exerciseIDs: [String]
        public init(id: WorkoutID, name: String, exerciseIDs: [String]) {
            self.id = id
            self.name = name
            self.exerciseIDs = exerciseIDs
        }
    }

    public var revision: Int
    public var warmUpDescription: String
    public var stretchDescription: String
    /// All exercises, archived ones included (kept so history stays readable).
    public var exercises: [Exercise]
    public var workouts: [WorkoutEntry]

    public init(revision: Int, warmUpDescription: String, stretchDescription: String, exercises: [Exercise],
                workouts: [WorkoutEntry]) {
        self.revision = revision
        self.warmUpDescription = warmUpDescription
        self.stretchDescription = stretchDescription
        self.exercises = exercises
        self.workouts = workouts
    }

    /// Built-in catalog from `WorkoutLibrary` (revision 0).
    public static let builtIn: Catalog = Catalog(
        revision: 0,
        warmUpDescription: WorkoutLibrary.warmUpDescription,
        stretchDescription: WorkoutLibrary.stretchDescription,
        exercises: WorkoutLibrary.all.flatMap(\.exercises),
        workouts: WorkoutLibrary.all.map { WorkoutEntry(id: $0.id, name: $0.name, exerciseIDs: $0.exercises.map(\.id)) }
    )

    public func exercise(id: String) -> Exercise? {
        exercises.first { $0.id == id }
    }

    /// The resolved workout. Falls back to the built-in definition if the catalog is broken
    /// (a validated catalog never is).
    public func workout(_ id: WorkoutID) -> Workout {
        guard let entry = workouts.first(where: { $0.id == id }) else { return WorkoutLibrary.workout(id) }
        let list = entry.exerciseIDs.compactMap { exercise(id: $0) }
        guard !list.isEmpty else { return WorkoutLibrary.workout(id) }
        return Workout(id: id, name: entry.name, exercises: list)
    }

    // MARK: Validation (same rules as the server, SERVER-SPEC §4.1)

    public static let exerciseIDPattern = "^[a-z0-9][a-z0-9-]{1,39}$"

    /// Empty = valid.
    public func validate() -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for e in exercises {
            if e.id.range(of: Self.exerciseIDPattern, options: .regularExpression) == nil {
                errors.append("exercise \(e.id): invalid id")
            }
            if !seen.insert(e.id).inserted { errors.append("exercise \(e.id): duplicate id") }
            if !(1...60).contains(e.name.count) { errors.append("exercise \(e.id): name length") }
            if e.techniqueTip.count > 200 { errors.append("exercise \(e.id): tip too long") }
            if (e.instructions?.count ?? 0) > 2000 { errors.append("exercise \(e.id): instructions too long") }
            switch e.target {
            case let .reps(min, max):
                if !(1...100).contains(min) || !(1...100).contains(max) || min > max {
                    errors.append("exercise \(e.id): reps range")
                }
            case let .time(min, max):
                if !(5...300).contains(min) || !(5...300).contains(max) || min > max {
                    errors.append("exercise \(e.id): time range")
                }
            }
            if e.switchesSideMidway && !e.perSide { errors.append("exercise \(e.id): side switch without perSide") }
        }
        for id in WorkoutID.allCases {
            guard let w = workouts.first(where: { $0.id == id }) else {
                errors.append("workout \(id.rawValue): missing")
                continue
            }
            if !(1...8).contains(w.exerciseIDs.count) { errors.append("workout \(id.rawValue): 1–8 exercises") }
            if Set(w.exerciseIDs).count != w.exerciseIDs.count { errors.append("workout \(id.rawValue): duplicates") }
            for exID in w.exerciseIDs {
                guard let e = exercise(id: exID) else {
                    errors.append("workout \(id.rawValue): unknown exercise \(exID)")
                    continue
                }
                if e.isArchived { errors.append("workout \(id.rawValue): archived exercise \(exID)") }
            }
            if !(1...60).contains(w.name.count) { errors.append("workout \(id.rawValue): name length") }
        }
        for (name, text) in [("warmUpDescription", warmUpDescription), ("stretchDescription", stretchDescription)]
        where !(1...500).contains(text.count) {
            errors.append("\(name): length")
        }
        return errors
    }
}
