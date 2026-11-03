import Foundation
@testable import TrainingCore

enum T {
    static let cal: Calendar = .prague

    /// Local Europe/Prague date.
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = s
        return cal.date(from: c)!
    }

    static func session(_ day: Date, _ id: WorkoutID, completed: Bool = true, kind: SessionKind = .planned,
                        rounds: Int = 3, weight: DumbbellWeight = .kg2, difficulty: Int? = 3,
                        timings: [PhaseTiming] = [], plannedSeconds: TimeInterval = 1140) -> Session {
        let start = cal.date(bySettingHour: 19, minute: 0, second: 0, of: day)!
        return Session(date: start, workoutID: id, kind: kind, rounds: rounds, weight: weight,
                       difficulty: difficulty.flatMap(Difficulty.init), completed: completed,
                       timings: timings, plannedSeconds: plannedSeconds, finishedAt: start + 1500)
    }

    static func hm(_ d: Date) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }
}
