import Foundation

/// Everything the app stores locally (offline, on-device only; no accounts, no telemetry).
public struct TrainingData: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var settings: Settings
    public var planStart: Date
    public var sessions: [Session]
    public var postponements: [Postponement]

    public init(schemaVersion: Int = TrainingData.currentSchemaVersion, settings: Settings = .default, planStart: Date,
                sessions: [Session] = [], postponements: [Postponement] = []) {
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.planStart = planStart
        self.sessions = sessions
        self.postponements = postponements
    }

    public var history: PlannerHistory {
        PlannerHistory(planStart: planStart, sessions: sessions, postponements: postponements)
    }

    /// Inserts or replaces a session by id (used for watch/phone sync merges).
    public mutating func upsert(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
            sessions.sort { $0.date < $1.date }
        }
    }
}

public protocol PersistenceStore: Sendable {
    func load() throws -> TrainingData?
    func save(_ data: TrainingData) throws
}

/// JSON file store. The app points it at its App Group container.
public struct JSONFilePersistenceStore: PersistenceStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> TrainingData? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try Self.makeDecoder().decode(TrainingData.self, from: data)
    }

    public func save(_ data: TrainingData) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = try Self.makeEncoder().encode(data)
        try bytes.write(to: fileURL, options: [.atomic])
    }
}

/// In-memory store for previews and tests.
public final class InMemoryPersistenceStore: PersistenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: TrainingData?
    public init(_ data: TrainingData? = nil) { self.data = data }
    public func load() throws -> TrainingData? { lock.lock(); defer { lock.unlock() }; return data }
    public func save(_ data: TrainingData) throws { lock.lock(); self.data = data; lock.unlock() }
}
