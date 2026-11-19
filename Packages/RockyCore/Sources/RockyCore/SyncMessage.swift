import Foundation

/// Messages exchanged between iPhone and Apple Watch over WatchConnectivity.
/// Commands carry the timestamp at which they happened so both engines stay in lockstep
/// regardless of transport latency (target: mirrored within 2 s, PRD 8a).
public enum SyncMessage: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case pause, resume, skip, back, abort
        /// "Hotovo": current exercise finished early.
        case done
    }

    public enum Origin: String, Codable, Sendable { case phone, watch }

    /// A workout was started on one device; the other should start the same plan at `startedAt`.
    /// `workout` = the exact definition the starting device uses (catalogs may differ between
    /// the devices); nil from older builds → the receiver uses its own catalog.
    case workoutStarted(sessionID: UUID, workoutID: WorkoutID, intervals: IntervalSettings, rounds: Int,
                        kind: SessionKind, startedAt: Date, origin: Origin, workout: Workout? = nil)
    case command(sessionID: UUID, command: Command, at: Date, origin: Origin)
    /// A finished (or aborted) session record to merge into local history.
    case sessionSaved(Session, origin: Origin)
    /// The workout was finished but discarded ("Neukládat") on one device; the other closes its
    /// summary without saving.
    case sessionDiscarded(sessionID: UUID, origin: Origin)
    /// Settings changed on the phone (watch mirrors relevant parts).
    case settingsChanged(Settings)
    /// The phone's active exercise catalog (from the server), without images (SERVER-SPEC §7).
    case catalogChanged(Catalog)
    /// Full live state of the running workout (replaces fire-and-forget commands, D-27).
    case liveState(LiveWorkout)

    public func encoded() throws -> Data {
        try JSONFilePersistenceStore.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncMessage {
        try JSONFilePersistenceStore.makeDecoder().decode(SyncMessage.self, from: data)
    }

    /// Dictionary form for WCSession `transferUserInfo` / `sendMessage`.
    public static let payloadKey = "payload"

    public func userInfo() throws -> [String: Any] { [Self.payloadKey: try encoded()] }

    public static func decode(userInfo: [String: Any]) throws -> SyncMessage? {
        guard let data = userInfo[payloadKey] as? Data else { return nil }
        return try decode(data)
    }
}

public extension WorkoutEngine {
    /// Applies a remote command at its original timestamp.
    @discardableResult
    mutating func apply(_ command: SyncMessage.Command, at date: Date) -> [EngineEvent] {
        switch command {
        case .pause: return pause(at: date)
        case .resume: return resume(at: date)
        case .skip: return skip(at: date)
        case .back: return back(at: date)
        case .abort: return abort(at: date)
        case .done: return finishEarly(at: date)
        }
    }
}
