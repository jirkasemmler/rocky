import Foundation

// Server sync (docs/SERVER-SPEC.md §5–6). Pure logic, no networking: the app's sync client does
// the HTTP calls and feeds the results in here. Conflicts are resolved by server versions (server
// wins), deletes are tombstones that win over updates.

public enum SyncRecordKind: String, Codable, Sendable, CaseIterable {
    case session, postponement, profile
}

/// Plan start and settings, so a fresh install can restore the replay of debt/rotation/streak.
public struct SyncProfile: Codable, Sendable, Equatable {
    public var planStart: Date
    public var settings: Settings
    public init(planStart: Date, settings: Settings) {
        self.planStart = planStart
        self.settings = settings
    }
}

public enum SyncPayload: Sendable, Equatable {
    case session(Session)
    case postponement(Postponement)
    case profile(SyncProfile)
}

/// One record of the server's changes feed / 409 body.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var kind: SyncRecordKind
    public var key: String
    public var version: Int
    public var changeSeq: Int
    public var deleted: Bool
    public var payload: SyncPayload?

    public init(kind: SyncRecordKind, key: String, version: Int, changeSeq: Int, deleted: Bool, payload: SyncPayload?) {
        self.kind = kind
        self.key = key
        self.version = version
        self.changeSeq = changeSeq
        self.deleted = deleted
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case kind, key, version, changeSeq, deleted, payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SyncRecordKind.self, forKey: .kind)
        key = try c.decode(String.self, forKey: .key)
        version = try c.decode(Int.self, forKey: .version)
        changeSeq = try c.decode(Int.self, forKey: .changeSeq)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        let payloadIsNil = try (!c.contains(.payload) || c.decodeNil(forKey: .payload))
        if deleted || payloadIsNil {
            payload = nil
        } else {
            switch kind {
            case .session: payload = .session(try c.decode(Session.self, forKey: .payload))
            case .postponement: payload = .postponement(try c.decode(Postponement.self, forKey: .payload))
            case .profile: payload = .profile(try c.decode(SyncProfile.self, forKey: .payload))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(key, forKey: .key)
        try c.encode(version, forKey: .version)
        try c.encode(changeSeq, forKey: .changeSeq)
        try c.encode(deleted, forKey: .deleted)
        switch payload {
        case let .session(s): try c.encode(s, forKey: .payload)
        case let .postponement(p): try c.encode(p, forKey: .payload)
        case let .profile(p): try c.encode(p, forKey: .payload)
        case nil: try c.encodeNil(forKey: .payload)
        }
    }
}

/// One page of `GET /changes`.
public struct ChangesPage: Codable, Sendable, Equatable {
    public var items: [SyncRecord]
    public var nextSince: Int
    public var hasMore: Bool
    public init(items: [SyncRecord], nextSince: Int, hasMore: Bool) {
        self.items = items
        self.nextSince = nextSince
        self.hasMore = hasMore
    }
}

public struct SyncOp: Codable, Sendable, Equatable, Hashable {
    public enum Op: String, Codable, Sendable { case upsert, delete }
    public var op: Op
    public var kind: SyncRecordKind
    public var key: String
    public init(op: Op, kind: SyncRecordKind, key: String) {
        self.op = op
        self.kind = kind
        self.key = key
    }
    public var recordID: String { SyncState.recordID(kind, key) }
}

/// Persistent client sync state (`sync-state.json`).
public struct SyncState: Codable, Sendable, Equatable {
    public var serverURL: String?
    public var lastChangeSeq: Int = 0
    /// "kind/key" → last known server version.
    public var knownVersions: [String: Int] = [:]
    public var outbox: [SyncOp] = []
    /// "kind/key" of locally deleted records; never resurrected (also not from the watch).
    public var tombstones: Set<String> = []
    public var catalogRevision: Int = 0
    /// The first full reconciliation with `serverURL` is done.
    public var didInitialSync = false
    public var lastSyncAt: Date?
    public var lastError: String?

    public init(serverURL: String? = nil) {
        self.serverURL = serverURL
    }

    public static func recordID(_ kind: SyncRecordKind, _ key: String) -> String { "\(kind.rawValue)/\(key)" }

    public func isTombstoned(_ kind: SyncRecordKind, _ key: String) -> Bool {
        tombstones.contains(Self.recordID(kind, key))
    }

    // MARK: Local changes → outbox

    /// A record was created or changed locally.
    public mutating func noteLocalUpsert(_ kind: SyncRecordKind, _ key: String) {
        let id = Self.recordID(kind, key)
        guard !tombstones.contains(id) else { return }
        outbox.removeAll { $0.recordID == id }
        outbox.append(SyncOp(op: .upsert, kind: kind, key: key))
    }

    /// A record was deleted locally: tombstone it and queue the delete (replaces a pending upsert).
    public mutating func noteLocalDelete(_ kind: SyncRecordKind, _ key: String) {
        let id = Self.recordID(kind, key)
        tombstones.insert(id)
        outbox.removeAll { $0.recordID == id }
        outbox.append(SyncOp(op: .delete, kind: kind, key: key))
    }

    /// Resets everything server-related (disconnect / different server). Tombstones are kept so
    /// deleted data does not come back from the watch.
    public mutating func reset(serverURL: String?) {
        let keep = tombstones
        self = SyncState(serverURL: serverURL)
        tombstones = keep
    }
}

public enum SyncKeys {
    public static func key(for session: Session) -> String { session.id.uuidString }
    public static let profileKey = "profile"
}

public extension TrainingData {
    /// Payload of a local record for upload, nil if it does not exist locally.
    func syncPayload(_ kind: SyncRecordKind, _ key: String, calendar: Calendar) -> SyncPayload? {
        switch kind {
        case .session:
            return sessions.first { $0.id.uuidString == key }.map(SyncPayload.session)
        case .postponement:
            return postponements.first { $0.dayKey(calendar: calendar) == key }.map(SyncPayload.postponement)
        case .profile:
            return .profile(SyncProfile(planStart: planStart, settings: settings))
        }
    }

    /// Keys of every local record (first sync uploads what the server lacks).
    func allSyncKeys(calendar: Calendar) -> [(SyncRecordKind, String)] {
        sessions.map { (.session, $0.id.uuidString) }
            + postponements.map { (.postponement, $0.dayKey(calendar: calendar)) }
            + [(.profile, SyncKeys.profileKey)]
    }

    /// No user data yet (fresh install / restore): the server profile may replace the local one.
    var isEmptyForRestore: Bool { sessions.isEmpty && postponements.isEmpty }
}

public extension Postponement {
    func dayKey(calendar: Calendar) -> String { day ?? Postponement.dayKey(for: date, calendar: calendar) }
}

/// Merges server records into local data.
public enum SyncMerger {
    /// Applies remote records. Records with a pending local op are skipped (the push resolves
    /// them); tombstoned keys stay deleted. Returns true if local data changed.
    @discardableResult
    public static func apply(_ records: [SyncRecord], to data: inout TrainingData, state: inout SyncState,
                             calendar: Calendar, allowProfileRestore: Bool) -> Bool {
        var changed = false
        let pending = Set(state.outbox.map(\.recordID))
        for record in records {
            let id = SyncState.recordID(record.kind, record.key)
            state.lastChangeSeq = max(state.lastChangeSeq, record.changeSeq)
            if pending.contains(id) { continue }
            state.knownVersions[id] = record.version
            if record.deleted {
                state.tombstones.insert(id)
                changed = remove(record.kind, record.key, from: &data, calendar: calendar) || changed
                continue
            }
            if state.tombstones.contains(id) { continue }
            changed = put(record.payload, to: &data, allowProfileRestore: allowProfileRestore, calendar: calendar) || changed
        }
        return changed
    }

    /// Server answered 409 with its current record: server wins.
    @discardableResult
    public static func resolveConflict(_ current: SyncRecord, to data: inout TrainingData, state: inout SyncState,
                                       calendar: Calendar) -> Bool {
        let id = SyncState.recordID(current.kind, current.key)
        state.outbox.removeAll { $0.recordID == id }
        return apply([current], to: &data, state: &state, calendar: calendar, allowProfileRestore: true)
    }

    /// Server answered 410 (tombstone): delete locally.
    @discardableResult
    public static func resolveGone(_ op: SyncOp, to data: inout TrainingData, state: inout SyncState,
                                   calendar: Calendar) -> Bool {
        state.outbox.removeAll { $0.recordID == op.recordID }
        state.tombstones.insert(op.recordID)
        return remove(op.kind, op.key, from: &data, calendar: calendar)
    }

    /// Successful upload / delete.
    public static func acknowledge(_ op: SyncOp, version: Int, state: inout SyncState) {
        if let i = state.outbox.firstIndex(of: op) { state.outbox.remove(at: i) }
        state.knownVersions[op.recordID] = version
    }

    /// First sync: queue an upsert for every local record the server did not report.
    public static func queueMissingLocalRecords(_ data: TrainingData, state: inout SyncState, calendar: Calendar) {
        for (kind, key) in data.allSyncKeys(calendar: calendar)
        where state.knownVersions[SyncState.recordID(kind, key)] == nil {
            state.noteLocalUpsert(kind, key)
        }
    }

    private static func remove(_ kind: SyncRecordKind, _ key: String, from data: inout TrainingData,
                               calendar: Calendar) -> Bool {
        switch kind {
        case .session:
            let before = data.sessions.count
            data.sessions.removeAll { $0.id.uuidString == key }
            return data.sessions.count != before
        case .postponement:
            let before = data.postponements.count
            data.postponements.removeAll { $0.dayKey(calendar: calendar) == key }
            return data.postponements.count != before
        case .profile:
            return false
        }
    }

    private static func put(_ payload: SyncPayload?, to data: inout TrainingData, allowProfileRestore: Bool,
                            calendar: Calendar) -> Bool {
        switch payload {
        case let .session(s):
            guard data.sessions.first(where: { $0.id == s.id }) != s else { return false }
            data.upsert(s)
            return true
        case let .postponement(p):
            let key = p.dayKey(calendar: calendar)
            var p = p
            p.day = key
            if data.postponements.first(where: { $0.dayKey(calendar: calendar) == key }) == p { return false }
            data.postponements.removeAll { $0.dayKey(calendar: calendar) == key }
            data.postponements.append(p)
            return true
        case let .profile(profile):
            guard allowProfileRestore, data.planStart != profile.planStart || data.settings != profile.settings
            else { return false }
            data.planStart = profile.planStart
            data.settings = profile.settings
            return true
        case nil:
            return false
        }
    }
}
