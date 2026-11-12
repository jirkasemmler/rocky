import XCTest
@testable import RockyCore

/// Contract with the Rocky server (SERVER-SPEC §3): the wire format is exactly the RockyCore
/// encoder output. `ROCKY_WRITE_FIXTURES=1 swift test --filter ServerFixtureTests` (re)writes the
/// fixtures under server/; a normal run checks that the committed fixtures and the server's own
/// response fixtures decode.
final class ServerFixtureTests: XCTestCase {
    private var serverDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server")
    }

    private var encoder: JSONEncoder {
        let e = JSONFilePersistenceStore.makeEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func sampleSession() -> Session {
        let clock = ManualTimeSource(T.date(2026, 11, 12, 19))
        let runner = WorkoutRunner(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA), timeSource: clock)
        runner.toggle(.water)
        runner.start()
        clock.advance(by: 185)
        runner.finishEarly() // squat (started at 180 s) finished early with "Hotovo"
        clock.advance(by: 30)
        runner.pause()
        clock.advance(by: 10)
        runner.resume()
        clock.advance(by: 2000)
        runner.tick()
        return runner.makeSession(id: UUID(uuidString: "6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10")!, kind: .catchUp,
                                  weight: .kg5, difficulty: Difficulty(4), note: "Kolena OK, plank těžký")
    }

    private var fixtures: [(String, Data)] {
        get throws {
            var seed = Catalog.builtIn
            seed.revision = 1
            let profile = SyncProfile(planStart: T.date(2026, 11, 2), settings: .default)
            let postponement = Postponement(date: T.date(2026, 11, 13, 8), reason: .illness, day: "2026-11-13")
            return [
                ("seed/catalog.json", try encoder.encode(seed)),
                ("tests/fixtures/session.json", try encoder.encode(sampleSession())),
                ("tests/fixtures/postponement.json", try encoder.encode(postponement)),
                ("tests/fixtures/profile.json", try encoder.encode(profile)),
            ]
        }
    }

    func testWriteOrVerifyFixtures() throws {
        let write = ProcessInfo.processInfo.environment["ROCKY_WRITE_FIXTURES"] == "1"
        for (path, data) in try fixtures {
            let url = serverDir.appendingPathComponent(path)
            if write {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                let committed = try Data(contentsOf: url)
                let decoder = JSONFilePersistenceStore.makeDecoder()
                switch path {
                case "seed/catalog.json": XCTAssertEqual(try decoder.decode(Catalog.self, from: committed).validate(), [])
                case "tests/fixtures/session.json": _ = try decoder.decode(Session.self, from: committed)
                case "tests/fixtures/postponement.json": _ = try decoder.decode(Postponement.self, from: committed)
                default: _ = try decoder.decode(SyncProfile.self, from: committed)
                }
            }
        }
    }

    /// Responses written by the server's test suite must decode in Swift.
    func testServerResponseFixturesDecode() throws {
        let dir = serverDir.appendingPathComponent("tests/fixtures")
        let decoder = JSONFilePersistenceStore.makeDecoder()
        let catalogURL = dir.appendingPathComponent("catalog_response.json")
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let catalog = try decoder.decode(Catalog.self, from: Data(contentsOf: catalogURL))
            XCTAssertEqual(catalog.validate(), [])
        }
        let changesURL = dir.appendingPathComponent("changes_response.json")
        if FileManager.default.fileExists(atPath: changesURL.path) {
            let page = try decoder.decode(ChangesPage.self, from: Data(contentsOf: changesURL))
            XCTAssertFalse(page.items.isEmpty)
        }
        let conflictURL = dir.appendingPathComponent("conflict_response.json")
        if FileManager.default.fileExists(atPath: conflictURL.path) {
            struct Conflict: Decodable { let current: SyncRecord }
            _ = try decoder.decode(Conflict.self, from: Data(contentsOf: conflictURL))
        }
    }
}
