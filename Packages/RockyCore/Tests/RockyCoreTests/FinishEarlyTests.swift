import XCTest
@testable import RockyCore

/// "Hotovo" button: finish the current exercise before the interval runs out.
final class FinishEarlyTests: XCTestCase {
    let t0 = T.date(2026, 11, 12, 19, 0)
    var plan: WorkoutPlan { WorkoutPlan(workout: WorkoutLibrary.workoutA) }

    func testFinishEarlyEndsExerciseAsDoneAndStartsRestNow() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180) // squat starts
        e.finishEarly(at: t0 + 205)
        XCTAssertEqual(e.currentPhase?.kind, .rest)
        let squat = e.timings.last!
        XCTAssertEqual(squat.endReason, .completedEarly)
        XCTAssertEqual(squat.actualSeconds, 25)
        // Rest starts at the tap, full length.
        XCTAssertEqual(e.snapshot(at: t0 + 205).remainingInPhase, 20)
    }

    func testEarlyFinishedExerciseIsAutoCheckedUnlikeSkip() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180)
        e.finishEarly(at: t0 + 190)
        XCTAssertTrue(e.completedExerciseChecks.contains(.init(round: 1, exerciseIndex: 0)))
        e.update(at: t0 + 5000)
        XCTAssertEqual(e.status, .finished)
        XCTAssertEqual(e.completedExerciseChecks.count, 12)
        XCTAssertEqual(e.completedRounds, [1, 2, 3])
    }

    func testNotAvailableDuringRest() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 225) // rest after squat
        XCTAssertEqual(e.currentPhase?.kind, .rest)
        XCTAssertFalse(e.canFinishEarly)
        e.finishEarly(at: t0 + 226)
        XCTAssertEqual(e.currentPhase?.kind, .rest, "rest is skipped with Přeskočit, not Hotovo")
    }

    func testWarmUpCanBeFinishedEarlyAndTicksChecklist() {
        let runner = WorkoutRunner(plan: plan, timeSource: ManualTimeSource(t0))
        runner.start()
        XCTAssertTrue(runner.engine.canFinishEarly)
        runner.finishEarly()
        XCTAssertEqual(runner.engine.currentPhase?.kind, .exercise)
        XCTAssertTrue(runner.checklist.pre.contains(.warmUpDone))
    }

    func testFinishEarlyWhilePausedStaysPaused() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180)
        e.pause(at: t0 + 190)
        e.finishEarly(at: t0 + 200)
        XCTAssertEqual(e.status, .paused)
        XCTAssertEqual(e.currentPhase?.kind, .rest)
    }

    func testDoneCommandSyncsAndStatsCountIt() throws {
        let id = UUID()
        let message = SyncMessage.command(sessionID: id, command: .done, at: t0, origin: .watch)
        XCTAssertEqual(try SyncMessage.decode(message.encoded()), message)

        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180)
        e.apply(.done, at: t0 + 200)
        XCTAssertEqual(e.timings.last?.endReason, .completedEarly)
        e.update(at: t0 + 5000)
        let session = Session(date: t0, workoutID: .a, rounds: 3, completed: true, timings: e.timings,
                              plannedSeconds: plan.plannedDuration)
        let summary = TimingStats.summarize(session)
        XCTAssertEqual(summary.finishedEarlyPhases, 1)
        XCTAssertEqual(summary.skippedPhases, 0)
    }
}
