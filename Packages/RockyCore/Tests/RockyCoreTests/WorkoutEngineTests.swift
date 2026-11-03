import XCTest
@testable import RockyCore

final class WorkoutEngineTests: XCTestCase {
    let t0 = T.date(2026, 11, 2, 19, 0)
    var plan: WorkoutPlan { WorkoutPlan(workout: WorkoutLibrary.workoutA) }

    func testStartEntersWarmUp() {
        var e = WorkoutEngine(plan: plan)
        XCTAssertEqual(e.status, .idle)
        let ev = e.start(at: t0)
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(e.status, .running)
        XCTAssertEqual(e.currentPhase?.kind, .warmUp)
        XCTAssertEqual(e.snapshot(at: t0 + 10).remainingInPhase, 170)
        XCTAssertEqual(e.snapshot(at: t0 + 10).displaySeconds, 170)
        XCTAssertEqual(e.snapshot(at: t0 + 10.3).displaySeconds, 170) // 169.7 rounds up
        XCTAssertTrue(e.start(at: t0 + 1).isEmpty, "start is idempotent")
    }

    func testTransitionsHappenAtExactBoundaries() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        XCTAssertTrue(e.update(at: t0 + 179.999).isEmpty)
        let ev = e.update(at: t0 + 180)
        XCTAssertEqual(e.currentPhase?.kind, .exercise)
        XCTAssertEqual(e.currentPhase?.exercise?.id, "squat")
        guard case let .phaseEnded(timing) = ev.first else { return XCTFail() }
        XCTAssertEqual(timing.kind, .warmUp)
        XCTAssertEqual(timing.actualSeconds, 180)
        XCTAssertEqual(timing.endReason, .completed)
    }

    /// Timing accuracy comes from timestamps, not tick counts: irregular, late ticks must not drift.
    func testNoDriftWithIrregularTicks() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        var now = t0
        var rng = SplitMix(seed: 42)
        while e.status == .running {
            now += Double(rng.next() % 900 + 50) / 1000 // 50..949 ms jittery ticks
            e.update(at: now)
        }
        XCTAssertEqual(e.status, .finished)
        XCTAssertEqual(e.endedAt, t0 + plan.plannedDuration, "finish time is exact despite jitter")
        // Every phase boundary is exactly at its planned offset.
        let offsets = plan.plannedOffsets
        for (i, t) in e.timings.enumerated() {
            XCTAssertEqual(t.startedAt, t0 + offsets[i], "phase \(i)")
            XCTAssertEqual(t.actualSeconds, t.plannedSeconds, accuracy: 1e-9)
        }
    }

    /// App suspended for a long time: one update processes all elapsed phases with exact timestamps.
    func testLargeJumpProcessesAllElapsedPhases() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        let ev = e.update(at: t0 + 290) // 180 warm-up + 40 squat + 20 rest + 40 push-up = 280, then rest (280-300)
        XCTAssertEqual(e.currentPhase?.kind, .rest)
        XCTAssertEqual(e.phaseIndex, 4)
        XCTAssertEqual(e.elapsedInPhase(at: t0 + 290), 10)
        XCTAssertEqual(e.timings.map(\.endedAt), [180, 220, 240, 280].map { t0 + $0 })
        XCTAssertEqual(ev.filter { if case .phaseEnded = $0 { return true } else { return false } }.count, 4)
    }

    func testPauseResumeExtendsPhaseAndRecordsPause() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180) // squat starts
        e.pause(at: t0 + 190)
        XCTAssertEqual(e.status, .paused)
        XCTAssertEqual(e.snapshot(at: t0 + 250).remainingInPhase, 30, "frozen while paused")
        XCTAssertTrue(e.update(at: t0 + 300).isEmpty, "no transitions while paused")
        e.resume(at: t0 + 310) // paused 120 s
        XCTAssertEqual(e.snapshot(at: t0 + 310).remainingInPhase, 30)
        XCTAssertTrue(e.update(at: t0 + 339.9).isEmpty)
        e.update(at: t0 + 340)
        XCTAssertEqual(e.currentPhase?.kind, .rest)
        let squat = e.timings.last!
        XCTAssertEqual(squat.pausedSeconds, 120)
        XCTAssertEqual(squat.actualSeconds, 160)
        XCTAssertEqual(squat.deviationSeconds, 120)
    }

    func testTogglePause() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.togglePause(at: t0 + 1)
        XCTAssertEqual(e.status, .paused)
        e.togglePause(at: t0 + 2)
        XCTAssertEqual(e.status, .running)
        XCTAssertTrue(e.resume(at: t0 + 3).isEmpty, "resume when running is a no-op")
    }

    func testSkipEndsPhaseNow() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.skip(at: t0 + 30)
        XCTAssertEqual(e.currentPhase?.kind, .exercise)
        XCTAssertEqual(e.timings[0].endReason, .skipped)
        XCTAssertEqual(e.timings[0].actualSeconds, 30)
        // New phase starts at the skip instant.
        XCTAssertEqual(e.snapshot(at: t0 + 40).remainingInPhase, 30)
    }

    func testSkipWhilePausedStaysPaused() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.pause(at: t0 + 10)
        e.skip(at: t0 + 20)
        XCTAssertEqual(e.status, .paused)
        XCTAssertEqual(e.currentPhase?.kind, .exercise)
        XCTAssertEqual(e.timings[0].pausedSeconds, 10)
        XCTAssertEqual(e.snapshot(at: t0 + 100).remainingInPhase, 40)
        e.resume(at: t0 + 100)
        e.update(at: t0 + 140)
        XCTAssertEqual(e.currentPhase?.kind, .rest)
    }

    func testBackFromRestGoesToPreviousExercise() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 225) // in rest after squat
        XCTAssertEqual(e.currentPhase?.kind, .rest)
        e.back(at: t0 + 225)
        XCTAssertEqual(e.currentPhase?.exercise?.id, "squat")
        XCTAssertEqual(e.snapshot(at: t0 + 225).remainingInPhase, 40)
        XCTAssertEqual(e.timings.last?.endReason, .back)
    }

    func testBackFromExerciseGoesToPreviousExercise() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 250) // push-up (starts at 240)
        XCTAssertEqual(e.currentPhase?.exercise?.id, "push-up")
        e.back(at: t0 + 250)
        XCTAssertEqual(e.currentPhase?.exercise?.id, "squat")
    }

    func testBackAtFirstExerciseOrWarmUpRestartsCurrent() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.back(at: t0 + 100)
        XCTAssertEqual(e.currentPhase?.kind, .warmUp)
        XCTAssertEqual(e.snapshot(at: t0 + 100).remainingInPhase, 180)
        e.skip(at: t0 + 101)
        e.back(at: t0 + 110)
        XCTAssertEqual(e.currentPhase?.exercise?.id, "squat")
        XCTAssertEqual(e.snapshot(at: t0 + 110).remainingInPhase, 40)
    }

    func testAbortMarksAborted() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.abort(at: t0 + 50)
        XCTAssertEqual(e.status, .aborted)
        XCTAssertNil(e.currentPhase)
        XCTAssertEqual(e.timings.last?.endReason, .aborted)
        XCTAssertTrue(e.update(at: t0 + 1000).isEmpty)
    }

    func testFullRunFinishesAndAutoChecksEverything() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        let ev = e.update(at: t0 + 2000)
        XCTAssertEqual(e.status, .finished)
        XCTAssertEqual(ev.last, .finished(at: t0 + 1140))
        XCTAssertEqual(e.completedExerciseChecks.count, 12)
        XCTAssertEqual(e.completedRounds, [1, 2, 3])
        XCTAssertEqual(e.snapshot(at: t0 + 3000).totalElapsed, 1140)
    }

    func testSkippedExerciseIsNotAutoChecked() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180)
        e.skip(at: t0 + 185) // skip squat round 1
        e.update(at: t0 + 5000)
        XCTAssertEqual(e.completedExerciseChecks.count, 11)
        XCTAssertEqual(e.completedRounds, [2, 3])
    }

    func testSnapshotRoundAndNext() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180 + 220 + 90 + 5) // round 2 squat
        let s = e.snapshot(at: t0 + 495)
        XCTAssertEqual(s.round, 2)
        XCTAssertEqual(s.totalRounds, 3)
        XCTAssertEqual(s.currentExercise?.id, "squat")
        XCTAssertEqual(s.nextExercise?.id, "push-up")
        XCTAssertEqual(s.plannedRemaining, 1140 - 495, accuracy: 1e-9)
    }

    func testTimerAccuracyWithin200msAt100msTicks() {
        // Simulate a 10 Hz UI tick: the engine must flip phases within one tick (<= 100 ms) of the boundary.
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        var now = t0
        var lastIndex = 0
        var maxLag: TimeInterval = 0
        let offsets = plan.plannedOffsets
        while e.status == .running {
            now += 0.1
            e.update(at: now)
            if e.phaseIndex != lastIndex, e.status == .running {
                maxLag = max(maxLag, now.timeIntervalSince(t0 + offsets[e.phaseIndex]))
                lastIndex = e.phaseIndex
            }
        }
        XCTAssertLessThanOrEqual(maxLag, 0.2)
    }

    func testRemoteCommandApply() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.apply(.pause, at: t0 + 5)
        XCTAssertEqual(e.status, .paused)
        e.apply(.resume, at: t0 + 6)
        e.apply(.skip, at: t0 + 7)
        XCTAssertEqual(e.currentPhase?.kind, .exercise)
    }
}

/// Small deterministic RNG for jitter tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
