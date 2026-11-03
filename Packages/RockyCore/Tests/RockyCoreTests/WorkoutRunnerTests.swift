import XCTest
@testable import RockyCore

final class WorkoutRunnerTests: XCTestCase {
    let t0 = T.date(2026, 11, 2, 19, 0)

    func testFullRunDeliversEveryCueExactlyOnceInOrder() {
        let clock = ManualTimeSource(t0)
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)
        let runner = WorkoutRunner(plan: plan, timeSource: clock)
        var delivered: [VoiceCue] = runner.start().cues
        while runner.engine.status == .running {
            clock.advance(by: 0.1)
            delivered += runner.tick().cues
        }
        let expected = runner.cueScheduler.allCues
        XCTAssertEqual(delivered.count, expected.count)
        XCTAssertEqual(delivered.map(\.id), runner.cueScheduler.timeline().map(\.cue.id))
        XCTAssertEqual(delivered.last?.kind, .workoutEnd)
    }

    func testCuesFireOnTime() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.start()
        clock.set(t0 + 180 + 40 + 13.9) // rest phase, just before announcement at 14 s
        XCTAssertFalse(runner.tick().cues.contains { $0.kind == .announceNext })
        clock.set(t0 + 180 + 40 + 14.05)
        XCTAssertEqual(runner.tick().cues.map(\.kind), [.announceNext])
    }

    func testStaleCuesDroppedAfterSuspensionButWorkoutEndKept() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.start()
        clock.set(t0 + 600) // app was suspended for 10 minutes
        let out = runner.tick()
        XCTAssertTrue(out.cues.count <= 2, "only cues within tolerance: \(out.cues.map(\.text))")
        clock.set(t0 + 5000)
        let end = runner.tick()
        XCTAssertEqual(end.cues.map(\.kind), [.workoutEnd])
        XCTAssertEqual(runner.engine.status, .finished)
    }

    func testPauseSilencesCues() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.start()
        clock.set(t0 + 170)
        runner.tick()
        runner.pause()
        clock.set(t0 + 400)
        XCTAssertTrue(runner.tick().cues.isEmpty)
        runner.resume()
        clock.advance(by: 4.05) // announcement at 174 (elapsed 174.05)
        XCTAssertEqual(runner.tick().cues.map(\.kind), [.announceNext])
    }

    func testSkipStartsNextPhaseWithItsStartCue() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.start()
        clock.advance(by: 5)
        let out = runner.skip()
        XCTAssertEqual(out.cues.map(\.text), ["Začínáme. Dřepy s činkami."])
    }

    func testBackReplaysPhaseCues() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.start()
        clock.set(t0 + 225)
        runner.tick()
        let out = runner.back()
        XCTAssertEqual(out.cues.first?.text, "Začínáme. Dřepy s činkami.")
    }

    func testChecklistAutoTickAndSession() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.toggle(.water)
        runner.toggle(.mat)
        runner.start()
        clock.set(t0 + 181)
        runner.tick()
        XCTAssertTrue(runner.checklist.pre.contains(.warmUpDone))
        clock.set(t0 + 2000)
        runner.tick()
        XCTAssertEqual(runner.checklist.exercises.count, 12)
        XCTAssertEqual(runner.checklist.rounds, [1, 2, 3])
        XCTAssertTrue(runner.checklist.post.contains(.stretchDone))

        let session = runner.makeSession(kind: .planned, weight: .kg5, difficulty: Difficulty(4), note: "OK")
        XCTAssertTrue(session.completed)
        XCTAssertEqual(session.workoutID, .a)
        XCTAssertEqual(session.rounds, 3)
        XCTAssertEqual(session.plannedSeconds, 1140)
        XCTAssertEqual(session.actualSeconds, 1140)
        XCTAssertEqual(session.timings.count, 25)
        XCTAssertTrue(session.checklist.post.contains(.difficultyLogged))
        XCTAssertEqual(session.checklist.pre, [.water, .mat, .warmUpDone])
    }

    func testAbortedSessionIsNotCompleted() {
        let clock = ManualTimeSource(t0)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutB), timeSource: clock)
        runner.start()
        clock.advance(by: 200)
        runner.abort()
        let s = runner.makeSession(kind: .planned, weight: .kg2, difficulty: nil, note: "")
        XCTAssertFalse(s.completed)
        XCTAssertFalse(s.checklist.post.contains(.difficultyLogged))
    }

    func testRemoteStartInThePastCatchesUp() {
        let clock = ManualTimeSource(t0 + 1.5)
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        let out = runner.start(at: t0)
        XCTAssertEqual(out.cues.first?.kind, .warmUpStart, "1.5 s late is within tolerance")
        XCTAssertEqual(runner.snapshot.elapsedInPhase, 1.5, accuracy: 1e-9)
        clock.advance(by: 1)
        runner.apply(.pause, at: t0 + 2)
        XCTAssertEqual(runner.engine.status, .paused)
        XCTAssertEqual(runner.snapshot.elapsedInPhase, 2, accuracy: 1e-9)
    }
}
