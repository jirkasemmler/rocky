import Foundation

/// Planned vs. actual timing of one session (PRD 8a "Měření timingu").
public struct SessionTimingSummary: Sendable, Equatable {
    public var plannedSeconds: TimeInterval
    public var actualSeconds: TimeInterval
    public var deviationSeconds: TimeInterval { actualSeconds - plannedSeconds }
    public var pausedSeconds: TimeInterval
    public var skippedPhases: Int
    /// Exercises (or warm-up / stretch) finished early with "Hotovo".
    public var finishedEarlyPhases: Int = 0
    /// Short rests between exercises.
    public var averageRestPlanned: TimeInterval?
    public var averageRestActual: TimeInterval?
    /// Rests between rounds.
    public var averageRoundRestActual: TimeInterval?
    public var exerciseSecondsActual: TimeInterval
    public var phases: [PhaseTiming]
}

public enum TimingSuggestion: Sendable, Equatable {
    /// Rests consistently overrun: offer a shorter planned rest so total time stays in budget.
    case shortenRest(currentSeconds: Int, suggestedSeconds: Int, averageActualSeconds: Int)
    /// The workout takes longer than the time budget (30 min): offer fewer rounds.
    case reduceRounds(from: Int, to: Int, actualMinutes: Int)

    /// Czech text for the UI.
    public var message: String {
        switch self {
        case let .shortenRest(current, suggested, avg):
            return "Pauzy ti trvale trvají déle (průměr \(avg) s místo \(current) s). Zkrátit pauzu na \(suggested) s?"
        case let .reduceRounds(from, to, minutes):
            return "Trénink trval \(minutes) min, tedy přes 30 minut. Snížit počet kol z \(from) na \(to)?"
        }
    }
}

public struct DayMinutes: Sendable, Equatable {
    public var day: Date
    public var minutes: Double
}

public enum TimingStats {
    /// Time budget from the PRD (20 to 30 min).
    public static let maxWorkoutSeconds: TimeInterval = 30 * 60

    public static func summarize(_ session: Session) -> SessionTimingSummary {
        summarize(timings: session.timings, plannedSeconds: session.plannedSeconds)
    }

    public static func summarize(timings: [PhaseTiming], plannedSeconds: TimeInterval) -> SessionTimingSummary {
        let rests = timings.filter { $0.kind == .rest }
        let roundRests = timings.filter { $0.kind == .roundRest }
        let actual: TimeInterval
        if let first = timings.map(\.startedAt).min(), let last = timings.map(\.endedAt).max() {
            actual = last.timeIntervalSince(first)
        } else {
            actual = 0
        }
        return SessionTimingSummary(
            plannedSeconds: plannedSeconds,
            actualSeconds: actual,
            pausedSeconds: timings.reduce(0) { $0 + $1.pausedSeconds },
            skippedPhases: timings.filter { $0.endReason == .skipped }.count,
            finishedEarlyPhases: timings.filter { $0.endReason == .completedEarly }.count,
            averageRestPlanned: average(rests.map(\.plannedSeconds)),
            averageRestActual: average(rests.map(\.actualSeconds)),
            averageRoundRestActual: average(roundRests.map(\.actualSeconds)),
            exerciseSecondsActual: timings.filter { $0.kind == .exercise }.reduce(0) { $0 + $1.actualSeconds },
            phases: timings
        )
    }

    /// Suggestions based on recent completed sessions (newest last or in any order).
    ///
    /// - shortenRest: the last `minSessions` completed sessions all had an average actual rest at
    ///   least `max(5 s, 25 %)` longer than planned. Suggests planned rest − 5 s (min 10 s).
    /// - reduceRounds: the most recent completed session took longer than 30 minutes and has more
    ///   than 2 rounds. Suggests one round fewer.
    public static func suggestions(recentSessions: [Session], intervals: IntervalSettings, minSessions: Int = 3) -> [TimingSuggestion] {
        let completed = recentSessions.filter(\.completed).sorted { $0.date < $1.date }
        var out: [TimingSuggestion] = []

        let window = completed.suffix(minSessions)
        if window.count >= minSessions, intervals.restSeconds > 10 {
            let planned = TimeInterval(intervals.restSeconds)
            let threshold = planned + max(5, planned * 0.25)
            let averages = window.compactMap { summarize($0).averageRestActual }
            if averages.count == window.count, averages.allSatisfy({ $0 >= threshold }) {
                let avg = averages.reduce(0, +) / Double(averages.count)
                out.append(.shortenRest(currentSeconds: intervals.restSeconds,
                                        suggestedSeconds: max(10, intervals.restSeconds - 5),
                                        averageActualSeconds: Int(avg.rounded())))
            }
        }

        if let last = completed.last {
            let actual = summarize(last).actualSeconds > 0 ? summarize(last).actualSeconds : last.actualSeconds
            if actual > maxWorkoutSeconds, last.rounds > 2 {
                out.append(.reduceRounds(from: last.rounds, to: last.rounds - 1, actualMinutes: Int((actual / 60).rounded())))
            }
        }
        return out
    }

    /// Minutes trained per day for the Monday-first week containing `date` (for the week chart).
    public static func weeklyMinutes(sessions: [Session], weekContaining date: Date, calendar: Calendar) -> [DayMinutes] {
        var cal = calendar
        cal.firstWeekday = 2
        guard let week = cal.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return (0..<7).compactMap { offset -> DayMinutes? in
            guard let day = cal.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let total = sessions
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .reduce(0.0) { $0 + $1.actualSeconds }
            return DayMinutes(day: day, minutes: total / 60)
        }
    }

    private static func average(_ xs: [TimeInterval]) -> TimeInterval? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}
