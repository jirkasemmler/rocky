import XCTest
@testable import RockyCore

/// Client side of the server sync (SERVER-SPEC §6): outbox, tombstones, merge, conflicts.
final class ServerSyncTests: XCTestCase {
    let cal = T.cal

    private func data() -> TrainingData {
        TrainingData(planStart: T.date(2026, 11, 2),
                     sessions: [T.session(T.date(2026, 11, 2, 19), .a)],
                     postponements: [Postponement(date: T.date(2026, 11, 4, 9), reason: .travel, day: "2026-11-04")])
    }

    private func record(_ s: Session, version: Int = 1, seq: Int) -> SyncRecord {
        SyncRecord(kind: .session, key: s.id.uuidString, version: version, changeSeq: seq, deleted: false, payload: .session(s))
    }

    func testFirstSyncQueuesEveryLocalRecordTheServerLacks() {
        var state = SyncState(serverURL: "https://rocky.example.ts.net")
        let local = data()
        SyncMerger.queueMissingLocalRecords(local, state: &state, calendar: cal)
        XCTAssertEqual(Set(state.outbox.map(\.kind)), [.session, .postponement, .profile])
        XCTAssertEqual(state.outbox.count, 3)
        XCTAssertTrue(state.outbox.contains(SyncOp(op: .upsert, kind: .postponement, key: "2026-11-04")))
    }

    func testPullImportsRemoteSessionsAndAdvancesCursor() {
        var local = data()
        var state = SyncState()
        let remote = T.session(T.date(2026, 11, 4, 19), .b)
        let changed = SyncMerger.apply([record(remote, seq: 7)], to: &local, state: &state, calendar: cal,
                                       allowProfileRestore: false)
        XCTAssertTrue(changed)
        XCTAssertEqual(local.sessions.count, 2)
        XCTAssertEqual(state.lastChangeSeq, 7)
        XCTAssertEqual(state.knownVersions["session/\(remote.id.uuidString)"], 1)
        // Re-applying the same page is a no-op.
        XCTAssertFalse(SyncMerger.apply([record(remote, seq: 7)], to: &local, state: &state, calendar: cal,
                                        allowProfileRestore: false))
    }

    func testLocalDeleteIsTombstonedAndNeverResurrected() {
        var local = data()
        var state = SyncState()
        let s = local.sessions[0]
        local.sessions.removeAll()
        state.noteLocalDelete(.session, s.id.uuidString)
        XCTAssertEqual(state.outbox, [SyncOp(op: .delete, kind: .session, key: s.id.uuidString)])
        // An older copy from the server (or the watch) must not bring it back.
        state.outbox.removeAll()
        SyncMerger.apply([record(s, seq: 3)], to: &local, state: &state, calendar: cal, allowProfileRestore: false)
        XCTAssertTrue(local.sessions.isEmpty)
        XCTAssertTrue(state.isTombstoned(.session, s.id.uuidString))
        // And a later local upsert of the same id is ignored.
        state.noteLocalUpsert(.session, s.id.uuidString)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testRemoteTombstoneDeletesLocally() {
        var local = data()
        var state = SyncState()
        let s = local.sessions[0]
        let tomb = SyncRecord(kind: .session, key: s.id.uuidString, version: 2, changeSeq: 9, deleted: true, payload: nil)
        SyncMerger.apply([tomb], to: &local, state: &state, calendar: cal, allowProfileRestore: false)
        XCTAssertTrue(local.sessions.isEmpty)
        XCTAssertTrue(state.isTombstoned(.session, s.id.uuidString))
    }

    func testPendingLocalOpWinsOverPulledRecordUntilPushed() {
        var local = data()
        var state = SyncState()
        var s = local.sessions[0]
        s.note = "local edit"
        local.upsert(s)
        state.noteLocalUpsert(.session, s.id.uuidString)
        var server = s
        server.note = "server"
        SyncMerger.apply([record(server, version: 4, seq: 10)], to: &local, state: &state, calendar: cal,
                         allowProfileRestore: false)
        XCTAssertEqual(local.sessions[0].note, "local edit")
        XCTAssertEqual(state.lastChangeSeq, 10)
    }

    func testConflictServerWinsAndDropsTheOp() {
        var local = data()
        var state = SyncState()
        var s = local.sessions[0]
        state.noteLocalUpsert(.session, s.id.uuidString)
        s.note = "from server"
        SyncMerger.resolveConflict(record(s, version: 5, seq: 11), to: &local, state: &state, calendar: cal)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(local.sessions[0].note, "from server")
        XCTAssertEqual(state.knownVersions["session/\(s.id.uuidString)"], 5)
    }

    func testGoneDeletesLocally() {
        var local = data()
        var state = SyncState()
        let op = SyncOp(op: .upsert, kind: .session, key: local.sessions[0].id.uuidString)
        state.outbox = [op]
        SyncMerger.resolveGone(op, to: &local, state: &state, calendar: cal)
        XCTAssertTrue(local.sessions.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testProfileRestoredOnlyWhenAllowed() {
        var local = TrainingData(planStart: T.date(2026, 11, 12))
        var state = SyncState()
        var settings = Settings.default
        settings.trainingDays = [.tuesday, .thursday, .saturday]
        let profile = SyncRecord(kind: .profile, key: "profile", version: 3, changeSeq: 2, deleted: false,
                                 payload: .profile(SyncProfile(planStart: T.date(2026, 10, 1), settings: settings)))
        SyncMerger.apply([profile], to: &local, state: &state, calendar: cal, allowProfileRestore: false)
        XCTAssertEqual(local.planStart, T.date(2026, 11, 12), "existing install keeps its own profile")
        XCTAssertTrue(local.isEmptyForRestore)
        SyncMerger.apply([profile], to: &local, state: &state, calendar: cal, allowProfileRestore: true)
        XCTAssertEqual(local.planStart, T.date(2026, 10, 1))
        XCTAssertEqual(local.settings.trainingDays, [.tuesday, .thursday, .saturday])
    }

    func testAcknowledgeStoresVersion() {
        var state = SyncState()
        let op = SyncOp(op: .upsert, kind: .profile, key: "profile")
        state.outbox = [op]
        SyncMerger.acknowledge(op, version: 2, state: &state)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(state.knownVersions["profile/profile"], 2)
    }

    func testResetKeepsTombstones() {
        var state = SyncState(serverURL: "a")
        state.noteLocalDelete(.session, "X")
        state.lastChangeSeq = 50
        state.reset(serverURL: "b")
        XCTAssertEqual(state.lastChangeSeq, 0)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertTrue(state.isTombstoned(.session, "X"))
    }

    func testCatalogBuiltInIsValidAndResolvesWorkouts() {
        XCTAssertEqual(Catalog.builtIn.validate(), [])
        XCTAssertEqual(Catalog.builtIn.workout(.b).exercises.map(\.id), WorkoutLibrary.workoutB.exercises.map(\.id))
    }

    func testCatalogValidationCatchesBadData() {
        var c = Catalog.builtIn
        c.exercises[0].target = .reps(min: 15, max: 12)
        c.exercises[1].archived = true // push-up is in workout A
        c.workouts.removeLast()
        let errors = c.validate()
        XCTAssertTrue(errors.contains { $0.contains("reps range") })
        XCTAssertTrue(errors.contains { $0.contains("archived exercise push-up") })
        XCTAssertTrue(errors.contains { $0.contains("workout C: missing") })
    }

    func testStartMessageCarriesWorkoutAndOldMessagesStillDecode() throws {
        let w = Catalog.builtIn.workout(.c)
        let msg = SyncMessage.workoutStarted(sessionID: UUID(), workoutID: .c, intervals: .default, rounds: 3, kind: .planned,
                                             startedAt: T.date(2026, 11, 12, 19), origin: .phone, workout: w)
        XCTAssertEqual(try SyncMessage.decode(msg.encoded()), msg)
        let old = #"{"workoutStarted":{"sessionID":"6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10","workoutID":"A","intervals":{"workSeconds":40,"restSeconds":20,"roundRestSeconds":90,"rounds":3,"warmUpSeconds":180,"stretchSeconds":120},"rounds":3,"kind":"planned","startedAt":"2026-11-12T18:00:00Z","origin":"watch"}}"#
        guard case let .workoutStarted(_, _, _, _, _, _, _, workout) = try SyncMessage.decode(Data(old.utf8)) else {
            return XCTFail()
        }
        XCTAssertNil(workout)
    }

    func testSessionFromRunnerEmbedsItsWorkout() {
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutB),
                                   timeSource: ManualTimeSource(T.date(2026, 11, 12, 19)))
        runner.start()
        let s = runner.makeSession(kind: .planned, weight: .kg2, difficulty: nil, note: "")
        XCTAssertEqual(s.workout?.id, .b)
        XCTAssertEqual(s.workout?.exercises.count, 4)
    }
}
