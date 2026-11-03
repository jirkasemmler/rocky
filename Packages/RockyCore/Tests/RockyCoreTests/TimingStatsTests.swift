import XCTest
@testable import RockyCore

final class TimingStatsTests: XCTestCase {
    let t0 = T.date(2026, 11, 2, 19, 0)

    private func run(restPause: TimeInterval = 0, rounds: Int = 3, day: Date? = nil) -> Session {
        let start = day.map { T.cal.date(bySettingHour: 19, minute: 0, second: 0, of: $0)! } ?? t0
        var e = WorkoutEngine(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA, roundsOverride: rounds))
        e.start(at: start)
        var now = start
        var pausedPhases = Set<Int>()
        while e.status == .running {
            if restPause > 0, e.currentPhase?.kind == .rest, !pausedPhases.contains(e.phaseIndex) {
                pausedPhases.insert(e.phaseIndex)
                e.pause(at: now)
                now += restPause
                e.resume(at: now)
            }
            now += 0.5
            e.update(at: now)
        }
        return Session(date: start, workoutID: .a, rounds: rounds, completed: e.status == .finished,
                       timings: e.timings, plannedSeconds: e.plan.plannedDuration, finishedAt: e.endedAt)
    }

    func testSummaryPlannedVsActual() {
        let s = run(restPause: 10)
        let sum = TimingStats.summarize(s)
        XCTAssertEqual(sum.plannedSeconds, 1140)
        XCTAssertEqual(sum.actualSeconds, 1140 + 9 * 10)
        XCTAssertEqual(sum.deviationSeconds, 90)
        XCTAssertEqual(sum.pausedSeconds, 90)
        XCTAssertEqual(sum.averageRestPlanned, 20)
        XCTAssertEqual(sum.averageRestActual, 30)
        XCTAssertEqual(sum.averageRoundRestActual, 90)
        XCTAssertEqual(sum.exerciseSecondsActual, 12 * 40)
        XCTAssertEqual(sum.skippedPhases, 0)
    }

    func testSkippedCountedAndShortensActual() {
        var e = WorkoutEngine(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA))
        e.start(at: t0)
        e.skip(at: t0 + 60) // skip 120 s of warm-up
        e.update(at: t0 + 5000)
        let sum = TimingStats.summarize(timings: e.timings, plannedSeconds: 1140)
        XCTAssertEqual(sum.skippedPhases, 1)
        XCTAssertEqual(sum.actualSeconds, 1020)
        XCTAssertEqual(sum.deviationSeconds, -120)
    }

    func testSuggestShortenRestWhenConsistentlyLonger() {
        let sessions = (0..<3).map { run(restPause: 10, day: T.date(2026, 11, 2 + 2 * $0)) }
        let sug = TimingStats.suggestions(recentSessions: sessions, intervals: .default)
        XCTAssertEqual(sug, [.shortenRest(currentSeconds: 20, suggestedSeconds: 15, averageActualSeconds: 30)])
        XCTAssertTrue(sug[0].message.contains("Zkrátit pauzu na 15 s"))
    }

    func testNoRestSuggestionIfNotConsistent() {
        let sessions = [run(restPause: 10, day: T.date(2026, 11, 2)), run(day: T.date(2026, 11, 4)),
                        run(restPause: 10, day: T.date(2026, 11, 6))]
        XCTAssertTrue(TimingStats.suggestions(recentSessions: sessions, intervals: .default).isEmpty)
        // fewer than 3 sessions: no suggestion
        XCTAssertTrue(TimingStats.suggestions(recentSessions: Array(sessions.prefix(1)), intervals: .default).isEmpty)
    }

    func testSmallOverrunIgnored() {
        let sessions = (0..<3).map { run(restPause: 3, day: T.date(2026, 11, 2 + 2 * $0)) }
        XCTAssertTrue(TimingStats.suggestions(recentSessions: sessions, intervals: .default).isEmpty)
    }

    func testSuggestFewerRoundsOver30Minutes() {
        // 9 rests x 60 s pause = +540 s -> 1680 s = 28 min: not over
        XCTAssertFalse(TimingStats.suggestions(recentSessions: [run(restPause: 60)], intervals: .default)
            .contains { if case .reduceRounds = $0 { return true } else { return false } })
        // 9 x 80 = +720 -> 1860 s = 31 min
        let sug = TimingStats.suggestions(recentSessions: [run(restPause: 80)], intervals: .default)
        XCTAssertTrue(sug.contains(.reduceRounds(from: 3, to: 2, actualMinutes: 31)))
    }

    func testNeverSuggestBelowTwoRounds() {
        // 2 rounds with long pauses: already the shortened version, do not go to 1
        let long = run(restPause: 200, rounds: 2)
        XCTAssertGreaterThan(long.actualSeconds, 1800)
        XCTAssertFalse(TimingStats.suggestions(recentSessions: [long], intervals: .default)
            .contains { if case .reduceRounds = $0 { return true } else { return false } })
    }

    func testIncompleteSessionsIgnored() {
        var s = run(restPause: 80)
        s.completed = false
        XCTAssertTrue(TimingStats.suggestions(recentSessions: [s], intervals: .default).isEmpty)
    }

    func testWeeklyMinutes() {
        let s1 = run(day: T.date(2026, 11, 2))
        let s2 = run(restPause: 10, day: T.date(2026, 11, 4))
        let week = TimingStats.weeklyMinutes(sessions: [s1, s2], weekContaining: T.date(2026, 11, 5, 12), calendar: T.cal)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week[0].day, T.date(2026, 11, 2))
        XCTAssertEqual(week[0].minutes, 19, accuracy: 0.001)
        XCTAssertEqual(week[2].minutes, 20.5, accuracy: 0.001)
        XCTAssertEqual(week[1].minutes, 0)
    }
}
