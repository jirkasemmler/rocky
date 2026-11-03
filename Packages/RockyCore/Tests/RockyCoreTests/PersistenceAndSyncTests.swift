import XCTest
@testable import RockyCore

final class PersistenceAndSyncTests: XCTestCase {
    private func sampleData() -> TrainingData {
        let clock = ManualTimeSource(T.date(2026, 11, 2, 19))
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.toggle(.water)
        runner.start()
        clock.advance(by: 300)
        runner.pause()
        clock.advance(by: 30)
        runner.resume()
        clock.advance(by: 2000)
        runner.tick()
        let session = runner.makeSession(kind: .planned, weight: .kg2, difficulty: Difficulty(3), note: "Šlo to dobře, kolena OK")
        return TrainingData(planStart: T.date(2026, 11, 2), sessions: [session],
                            postponements: [Postponement(date: T.date(2026, 11, 3, 10), reason: .travel)])
    }

    func testJSONFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFilePersistenceStore(fileURL: dir.appendingPathComponent("nested/data.json"))
        XCTAssertNil(try store.load())
        let data = sampleData()
        try store.save(data)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, data)
        XCTAssertEqual(loaded.sessions[0].note, "Šlo to dobře, kolena OK")
        XCTAssertEqual(loaded.sessions[0].timings.count, data.sessions[0].timings.count)
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testInvalidDifficultyRejected() {
        let json = #"5"#.data(using: .utf8)!
        XCTAssertNoThrow(try JSONDecoder().decode(Difficulty.self, from: json))
        XCTAssertThrowsError(try JSONDecoder().decode(Difficulty.self, from: #"9"#.data(using: .utf8)!))
    }

    func testUpsertReplacesById() {
        var data = sampleData()
        var s = data.sessions[0]
        s.note = "upraveno"
        data.upsert(s)
        XCTAssertEqual(data.sessions.count, 1)
        XCTAssertEqual(data.sessions[0].note, "upraveno")
        data.upsert(T.session(T.date(2026, 11, 1), .c))
        XCTAssertEqual(data.sessions.count, 2)
        XCTAssertEqual(data.sessions.first?.workoutID, .c, "kept sorted by date")
    }

    func testInMemoryStore() throws {
        let store = InMemoryPersistenceStore()
        XCTAssertNil(try store.load())
        try store.save(sampleData())
        XCTAssertEqual(try store.load()?.sessions.count, 1)
    }

    func testSyncMessagesRoundTrip() throws {
        let id = UUID()
        let messages: [SyncMessage] = [
            .workoutStarted(sessionID: id, workoutID: .b, intervals: .default, rounds: 2, kind: .catchUp,
                            startedAt: T.date(2026, 11, 3, 19), origin: .watch),
            .command(sessionID: id, command: .skip, at: T.date(2026, 11, 3, 19, 5), origin: .phone),
            .sessionSaved(sampleData().sessions[0], origin: .watch),
            .settingsChanged(.default),
        ]
        for m in messages {
            XCTAssertEqual(try SyncMessage.decode(m.encoded()), m)
            XCTAssertEqual(try SyncMessage.decode(userInfo: m.userInfo()), m)
        }
        XCTAssertNil(try SyncMessage.decode(userInfo: ["x": 1]))
    }

    func testSettingsDefaultsMatchProposedDecisions() {
        let s = Settings.default
        XCTAssertEqual(s.trainingDays, [.monday, .wednesday, .friday])
        XCTAssertEqual(s.latestEscalation, TimeOfDay(hour: 22, minute: 30))
        XCTAssertTrue(s.voiceEnabled)
        XCTAssertNil(s.voiceIdentifier, "nil = default Czech voice (Zuzana)")
        XCTAssertEqual(s.speechRate, 0.5)
        XCTAssertFalse(s.watchSoundEnabled)
    }
}
