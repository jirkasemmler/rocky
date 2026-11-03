import XCTest
@testable import RockyCore

final class WorkoutPlanTests: XCTestCase {
    func testDefaultPlanStructure() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)
        // warm-up + 3 rounds x (4 exercises + 3 rests) + 2 round rests + stretch
        XCTAssertEqual(plan.phases.count, 1 + 3 * 7 + 2 + 1)
        XCTAssertEqual(plan.phases.first?.kind, .warmUp)
        XCTAssertEqual(plan.phases.last?.kind, .stretch)
        XCTAssertEqual(plan.phases.filter { $0.kind == .exercise }.count, 12)
        XCTAssertEqual(plan.phases.filter { $0.kind == .rest }.count, 9)
        XCTAssertEqual(plan.phases.filter { $0.kind == .roundRest }.count, 2)
        XCTAssertEqual(plan.phases.map(\.index), Array(0..<plan.phases.count))
        // 180 + 3*(160+60) + 2*90 + 120 = 1140 s = 19 min
        XCTAssertEqual(plan.plannedDuration, 1140)
    }

    func testPhaseOrderAndRounds() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutB)
        let kinds = plan.phases.prefix(10).map(\.kind)
        XCTAssertEqual(kinds, [.warmUp, .exercise, .rest, .exercise, .rest, .exercise, .rest, .exercise, .roundRest, .exercise])
        XCTAssertEqual(plan.phases[1].round, 1)
        XCTAssertEqual(plan.phases[9].round, 2)
        XCTAssertEqual(plan.phases[9].exercise?.id, "reverse-lunge")
    }

    func testUpcomingExercise() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)
        XCTAssertEqual(plan.phases[0].upcomingExercise?.id, "squat")      // warm-up -> squat
        XCTAssertEqual(plan.phases[1].upcomingExercise?.id, "push-up")    // squat -> push-up
        XCTAssertEqual(plan.phases[2].upcomingExercise?.id, "push-up")    // rest -> push-up
        XCTAssertEqual(plan.phases[8].upcomingExercise?.id, "squat")      // round rest -> squat
        XCTAssertNil(plan.phases.last?.upcomingExercise)
        let lastExercise = plan.phases.last(where: { $0.kind == .exercise })!
        XCTAssertNil(lastExercise.upcomingExercise)
    }

    func testRoundsOverrideForShortenedVersion() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutC, roundsOverride: 2)
        XCTAssertEqual(plan.rounds, 2)
        XCTAssertEqual(plan.phases.filter { $0.kind == .exercise }.count, 8)
        XCTAssertEqual(plan.phases.filter { $0.kind == .roundRest }.count, 1)
        XCTAssertEqual(plan.plannedDuration, 180 + 2 * 220 + 90 + 120)
    }

    func testZeroRestAndNoWarmUpStillEndsWithFixedStretch() {
        let iv = IntervalSettings(workSeconds: 30, restSeconds: 0, roundRestSeconds: 0, rounds: 1, warmUpSeconds: 0)
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA, intervals: iv)
        XCTAssertEqual(plan.phases.map(\.kind), [.exercise, .exercise, .exercise, .exercise, .stretch])
        XCTAssertEqual(plan.plannedDuration, 120 + 120)
    }

    func testSanitizedClampsValues() {
        let iv = IntervalSettings(workSeconds: 1, restSeconds: -5, roundRestSeconds: 5000, rounds: 0).sanitized()
        XCTAssertEqual(iv.workSeconds, 5)
        XCTAssertEqual(iv.restSeconds, 0)
        XCTAssertEqual(iv.roundRestSeconds, 900)
        XCTAssertEqual(iv.rounds, 1)
    }

    func testPlannedOffsets() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)
        let offsets = plan.plannedOffsets
        XCTAssertEqual(offsets[0], 0)
        XCTAssertEqual(offsets[1], 180)
        XCTAssertEqual(offsets[2], 220)
        XCTAssertEqual(offsets.last, 1140 - 120)
    }
}
