import XCTest
@testable import RockyCore

/// Phone ⇄ watch live sync by replicated state (not fire-and-forget commands): lost messages heal
/// with the next state, and two independently started workouts converge on one.
final class LiveSyncTests: XCTestCase {
    let t0 = T.date(2026, 11, 19, 19, 0)
    var plan: WorkoutPlan { WorkoutPlan(workout: WorkoutLibrary.workoutA) }

    private func live(_ id: UUID, rev: Int, engine: WorkoutEngine, origin: SyncMessage.Origin) -> LiveWorkout {
        LiveWorkout(sessionID: id, revision: rev, workout: plan.workout, intervals: plan.intervals, rounds: plan.rounds,
                    kind: .planned, origin: origin, engine: engine.state)
    }

    func testEngineStateRoundTripKeepsTimeline() throws {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        e.update(at: t0 + 180)
        e.finishEarly(at: t0 + 200)
        e.pause(at: t0 + 205)
        let data = try JSONFilePersistenceStore.makeEncoder().encode(e.state)
        let decoded = try JSONFilePersistenceStore.makeDecoder().decode(EngineState.self, from: data)
        let copy = WorkoutEngine(plan: plan, state: decoded)
        XCTAssertEqual(copy.status, .paused)
        XCTAssertEqual(copy.phaseIndex, e.phaseIndex)
        XCTAssertEqual(copy.timings, e.timings)
        XCTAssertEqual(copy.snapshot(at: t0 + 300), e.snapshot(at: t0 + 300))
    }

    func testRunnerAdoptsRemoteStateAndReportsTransitions() {
        let clock = ManualTimeSource(t0)
        let watch = WorkoutRunner(plan: plan, timeSource: clock)
        let phone = WorkoutRunner(plan: plan, timeSource: clock)
        watch.start(); phone.start()
        clock.advance(by: 185)
        watch.tick(); phone.tick()
        watch.finishEarly() // "Hotovo" on the watch; the command message got lost
        clock.advance(by: 3)
        let out = phone.adopt(watch.engine.state)
        XCTAssertEqual(phone.engine.currentPhase?.kind, .rest)
        XCTAssertEqual(phone.engine.timings, watch.engine.timings)
        XCTAssertTrue(out.cues.isEmpty || out.cues.allSatisfy { $0.kind != .countdown }, "no stale countdown")
        // Abort on the watch → the phone ends too.
        watch.abort()
        let end = phone.adopt(watch.engine.state)
        XCTAssertEqual(phone.engine.status, .aborted)
        XCTAssertTrue(end.events.contains { if case .aborted = $0 { return true }; return false })
    }

    func testNewerRevisionWinsAndTieGoesToPhone() {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        let id = UUID()
        let a = live(id, rev: 3, engine: e, origin: .watch)
        let b = live(id, rev: 2, engine: e, origin: .phone)
        XCTAssertTrue(a.supersedes(b))
        XCTAssertFalse(b.supersedes(a))
        let c = live(id, rev: 3, engine: e, origin: .phone)
        XCTAssertTrue(c.supersedes(a), "same revision: phone wins, deterministic on both sides")
        XCTAssertFalse(a.supersedes(c))
    }

    func testTwoIndependentStartsConvergeOnTheEarlierOne() {
        var early = WorkoutEngine(plan: plan)
        early.start(at: t0)
        var late = WorkoutEngine(plan: plan)
        late.start(at: t0 + 4)
        let watchRun = live(UUID(), rev: 1, engine: early, origin: .watch)
        let phoneRun = live(UUID(), rev: 5, engine: late, origin: .phone)
        // Both devices evaluate the same rule and keep the earlier start.
        XCTAssertTrue(watchRun.supersedes(phoneRun))
        XCTAssertFalse(phoneRun.supersedes(watchRun))
    }

    func testStaleOrFinishedStatesAreNotAdoptedWhenIdle() {
        var finished = WorkoutEngine(plan: plan)
        finished.start(at: t0)
        finished.update(at: t0 + 5000)
        XCTAssertFalse(live(UUID(), rev: 9, engine: finished, origin: .watch).isJoinable(at: t0 + 5001))
        var old = WorkoutEngine(plan: plan)
        old.start(at: t0)
        XCTAssertTrue(live(UUID(), rev: 1, engine: old, origin: .watch).isJoinable(at: t0 + 60))
        XCTAssertFalse(live(UUID(), rev: 1, engine: old, origin: .watch).isJoinable(at: t0 + 4 * 3600),
                       "a running state far past its plan is stale (e.g. late application context)")
    }

    func testLiveStateMessageRoundTrip() throws {
        var e = WorkoutEngine(plan: plan)
        e.start(at: t0)
        let msg = SyncMessage.liveState(live(UUID(), rev: 4, engine: e, origin: .phone))
        XCTAssertEqual(try SyncMessage.decode(msg.encoded()), msg)
    }
}
