import XCTest
@testable import TrainingCore

final class ProgressionAdvisorTests: XCTestCase {
    /// Mon/Wed/Fri sessions for two weeks starting Mon 2 Nov 2026.
    private func history(difficulty: Int, weight: DumbbellWeight, id: WorkoutID? = nil) -> [Session] {
        [2, 4, 6, 9, 11, 13].enumerated().map { i, d in
            T.session(T.date(2026, 11, d), id ?? WorkoutID.allCases[i % 3], weight: weight, difficulty: difficulty)
        }
    }

    func testNotYetBeforeTwoWeeks() {
        let advice = ProgressionAdvisor.advise(sessions: history(difficulty: 1, weight: .kg2), now: T.date(2026, 11, 13, 20), calendar: T.cal)
        XCTAssertEqual(advice.recommendation, .notYet(daysRemaining: 3))
        XCTAssertTrue(advice.recommendation.message.contains("3 dny"))
        let empty = ProgressionAdvisor.advise(sessions: [], now: T.date(2026, 11, 13), calendar: T.cal)
        XCTAssertEqual(empty.recommendation, .notYet(daysRemaining: 14))
    }

    func testEasyWith2kgSuggestsHeavier() {
        let a = ProgressionAdvisor.advise(sessions: history(difficulty: 2, weight: .kg2), now: T.date(2026, 11, 16, 20), calendar: T.cal)
        XCTAssertEqual(a.recommendation, .increaseWeight(from: .kg2, to: .kg5))
        XCTAssertEqual(a.recommendation.message, "Přejdi z 2 kg na 5 kg.")
        XCTAssertEqual(a.averageDifficulty, 2)
    }

    func testEasyWith5kgOrBodyweightAddsReps() {
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: history(difficulty: 1, weight: .kg5), now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .addReps)
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: history(difficulty: 2, weight: .none), now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .addReps)
    }

    func testMediumSuggestsSlowTempoHardKeeps() {
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: history(difficulty: 3, weight: .kg2), now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .slowTempo)
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: history(difficulty: 4, weight: .kg2), now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .keep)
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: history(difficulty: 5, weight: .kg5), now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .keep)
    }

    func testMixedAverage() {
        var s = history(difficulty: 2, weight: .kg2)
        s[0].difficulty = Difficulty(3)
        s[1].difficulty = Difficulty(3)
        s[2].difficulty = Difficulty(3) // avg 2.5
        XCTAssertEqual(ProgressionAdvisor.advise(sessions: s, now: T.date(2026, 11, 16), calendar: T.cal).recommendation, .addReps)
    }

    func testPerWorkoutFilterAndMinimumSessions() {
        let s = history(difficulty: 1, weight: .kg2)
        let a = ProgressionAdvisor.advise(sessions: s, workoutID: .a, now: T.date(2026, 11, 16), calendar: T.cal)
        XCTAssertEqual(a.sessionsConsidered, 2)
        XCTAssertEqual(a.recommendation, .keep, "not enough rated sessions of A")
    }

    func testOnlyLast14DaysAndOnlyCompletedRated() {
        var s = history(difficulty: 5, weight: .kg2) // old, hard
        s += [16, 18, 20].map { T.session(T.date(2026, 11, $0), .a, weight: .kg2, difficulty: 1) }
        s.append(T.session(T.date(2026, 11, 23), .b, completed: false, difficulty: 5))
        s.append(T.session(T.date(2026, 11, 23), .b, difficulty: nil))
        let a = ProgressionAdvisor.advise(sessions: s, now: T.date(2026, 11, 27), calendar: T.cal)
        // window = since 13 Nov: 13 (5), 16, 18, 20 (1) -> avg 2.0 with 2 kg
        XCTAssertEqual(a.sessionsConsidered, 4)
        XCTAssertEqual(a.averageDifficulty, 2.0)
        XCTAssertEqual(a.recommendation, .increaseWeight(from: .kg2, to: .kg5))
    }
}
