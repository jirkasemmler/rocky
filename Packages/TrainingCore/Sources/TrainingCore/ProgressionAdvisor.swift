import Foundation

public enum ProgressionRecommendation: Sendable, Equatable {
    /// Not enough history yet (PRD: recommendation after 2 weeks).
    case notYet(daysRemaining: Int)
    case addReps
    /// Slow down the lowering phase (3 s down).
    case slowTempo
    case increaseWeight(from: DumbbellWeight, to: DumbbellWeight)
    case keep

    public var message: String {
        switch self {
        case let .notYet(days):
            return "Doporučení postupu bude k dispozici za \(days) \(days == 1 ? "den" : (2...4).contains(days) ? "dny" : "dní")."
        case .addReps:
            return "Přidej opakování: zkus u každého cviku 1 až 2 opakování navíc."
        case .slowTempo:
            return "Zpomal spouštění: dolů počítej 3 sekundy."
        case let .increaseWeight(from, to):
            return "Přejdi z \(from.label) na \(to.label)."
        case .keep:
            return "Drž současnou zátěž, náročnost je tak akorát."
        }
    }
}

public struct ProgressionAdvice: Sendable, Equatable {
    public var workoutID: WorkoutID?
    public var recommendation: ProgressionRecommendation
    public var averageDifficulty: Double?
    public var sessionsConsidered: Int
}

/// PRD 3.7 / Appendix A: after 2 weeks recommend "add reps / slow tempo / go from 2 to 5 kg"
/// based on the logged difficulty (1-5).
///
/// Rules (window = last 14 days, at least `minSessions` rated completed sessions):
/// - avg ≤ 2.0 and weight 2 kg  -> increase to 5 kg
/// - avg ≤ 2.5                  -> add reps (bodyweight / already 5 kg / 2 kg but not that easy)
/// - avg ≤ 3.5                  -> slow tempo (3 s down)
/// - otherwise                  -> keep
public enum ProgressionAdvisor {
    public static let evaluationDays = 14

    public static func advise(sessions: [Session], workoutID: WorkoutID? = nil, now: Date, calendar: Calendar,
                              minSessions: Int = 3) -> ProgressionAdvice {
        let relevant = sessions
            .filter { $0.completed && (workoutID == nil || $0.workoutID == workoutID) }
            .sorted { $0.date < $1.date }

        guard let first = relevant.first else {
            return ProgressionAdvice(workoutID: workoutID, recommendation: .notYet(daysRemaining: evaluationDays),
                                     averageDifficulty: nil, sessionsConsidered: 0)
        }
        let startDay = calendar.startOfDay(for: first.date)
        let today = calendar.startOfDay(for: now)
        let daysSince = calendar.dateComponents([.day], from: startDay, to: today).day ?? 0
        if daysSince < evaluationDays {
            return ProgressionAdvice(workoutID: workoutID, recommendation: .notYet(daysRemaining: evaluationDays - daysSince),
                                     averageDifficulty: nil, sessionsConsidered: 0)
        }

        guard let windowStart = calendar.date(byAdding: .day, value: -evaluationDays, to: today) else {
            return ProgressionAdvice(workoutID: workoutID, recommendation: .keep, averageDifficulty: nil, sessionsConsidered: 0)
        }
        let window = relevant.filter { $0.date >= windowStart && $0.difficulty != nil }
        guard window.count >= minSessions else {
            return ProgressionAdvice(workoutID: workoutID, recommendation: .keep, averageDifficulty: nil,
                                     sessionsConsidered: window.count)
        }
        let avg = Double(window.compactMap { $0.difficulty?.value }.reduce(0, +)) / Double(window.count)
        // Most common recent weight (ties -> heavier), so one odd session does not flip the advice.
        let weight = dominantWeight(window)

        let rec: ProgressionRecommendation
        if avg <= 2.0, weight == .kg2 {
            rec = .increaseWeight(from: .kg2, to: .kg5)
        } else if avg <= 2.5 {
            rec = .addReps
        } else if avg <= 3.5 {
            rec = .slowTempo
        } else {
            rec = .keep
        }
        return ProgressionAdvice(workoutID: workoutID, recommendation: rec, averageDifficulty: avg, sessionsConsidered: window.count)
    }

    static func dominantWeight(_ sessions: [Session]) -> DumbbellWeight {
        var counts: [DumbbellWeight: Int] = [:]
        for s in sessions { counts[s.weight, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key ?? .none
    }
}
