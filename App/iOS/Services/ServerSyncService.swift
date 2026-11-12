import CryptoKit
import Foundation
import Observation
import RockyCore
import Security

/// Device token for the Rocky server, kept in the Keychain (never in the JSON files).
enum ServerTokenStore {
    private static let service = "cz.semmler.rocky.server"
    private static let account = "device-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Syncs with the optional Rocky server (SERVER-SPEC §6): catalog + images down, sessions /
/// postponements / profile both ways. Offline first: failures only show up in Settings.
@MainActor
@Observable
final class ServerSyncService {
    private(set) var isSyncing = false
    private(set) var statusText: String?

    @ObservationIgnored private let store: TrainingStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private let encoder = JSONFilePersistenceStore.makeEncoder()
    @ObservationIgnored private let decoder = JSONFilePersistenceStore.makeDecoder()

    init(store: TrainingStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    var isConfigured: Bool { store.syncState.serverURL != nil && ServerTokenStore.load() != nil }

    // MARK: Setup

    /// Connects to a server (or a different one): resets the sync state, then runs the first sync.
    func connect(serverURL: String, token: String) async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ServerTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        store.updateSyncState { $0.reset(serverURL: trimmed) }
        await syncNow()
    }

    func disconnect() {
        ServerTokenStore.save(nil)
        store.updateSyncState { $0.reset(serverURL: nil) }
        statusText = nil
    }

    /// After a local change: sync in 2 s (coalesces bursts of changes).
    func scheduleSync() {
        guard isConfigured else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// On foreground: at most every 5 minutes.
    func syncIfStale() {
        guard isConfigured else { return }
        if let last = store.syncState.lastSyncAt, Date().timeIntervalSince(last) < 300 { return }
        Task { await syncNow() }
    }

    // MARK: Sync

    func syncNow() async {
        guard !isSyncing, let base = store.syncState.serverURL.flatMap(URL.init(string:)),
              let token = ServerTokenStore.load() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let api = API(base: base, token: token, session: session)
        do {
            try await syncCatalog(api)
            if !store.syncState.didInitialSync {
                try await pullAll(api, restoreProfile: store.data.isEmptyForRestore)
                store.updateSync { data, state in
                    SyncMerger.queueMissingLocalRecords(data, state: &state, calendar: store.calendar)
                    state.didInitialSync = true
                    return false
                }
            }
            try await push(api)
            try await pullAll(api, restoreProfile: false)
            store.updateSyncState {
                $0.lastSyncAt = Date()
                $0.lastError = nil
            }
            statusText = nil
            await downloadMissingImages(api)
        } catch {
            let message = (error as? SyncError)?.message ?? error.localizedDescription
            store.updateSyncState { $0.lastError = message }
            statusText = message
        }
    }

    private func syncCatalog(_ api: API) async throws {
        var headers: [String: String] = [:]
        if store.syncState.catalogRevision > 0 { headers["If-None-Match"] = "\"rev-\(store.syncState.catalogRevision)\"" }
        let (data, status) = try await api.request("GET", "/api/v1/catalog", headers: headers)
        if status == 304 { return }
        guard status == 200 else { throw SyncError.http(status, "katalog") }
        let catalog = try decoder.decode(Catalog.self, from: data)
        let errors = catalog.validate()
        guard errors.isEmpty else { throw SyncError(message: "Katalog ze serveru je neplatný: \(errors.first ?? "")") }
        store.applyCatalog(catalog)
        store.updateSyncState { $0.catalogRevision = catalog.revision }
    }

    private func pullAll(_ api: API, restoreProfile: Bool) async throws {
        while true {
            let since = store.syncState.lastChangeSeq
            let (data, status) = try await api.request("GET", "/api/v1/changes?since=\(since)&limit=500")
            guard status == 200 else { throw SyncError.http(status, "změny") }
            let page = try decoder.decode(ChangesPage.self, from: data)
            store.updateSync { local, state in
                let changed = SyncMerger.apply(page.items, to: &local, state: &state, calendar: store.calendar,
                                               allowProfileRestore: restoreProfile)
                state.lastChangeSeq = max(state.lastChangeSeq, page.nextSince)
                return changed
            }
            if !page.hasMore || page.items.isEmpty { return }
        }
    }

    private func push(_ api: API) async throws {
        while let op = store.syncState.outbox.first {
            let path = "/api/v1/records/\(op.kind.rawValue)/\(op.key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? op.key)"
            var headers: [String: String] = [:]
            if let version = store.syncState.knownVersions[op.recordID] {
                headers["If-Match"] = String(version)
            } else {
                headers[op.op == .delete ? "If-Match" : "If-None-Match"] = "*"
            }
            let response: (Data, Int)
            switch op.op {
            case .upsert:
                guard let payload = store.data.syncPayload(op.kind, op.key, calendar: store.calendar) else {
                    store.updateSyncState { $0.outbox.removeFirst() } // no longer exists locally
                    continue
                }
                headers["Content-Type"] = "application/json"
                response = try await api.request("PUT", path, headers: headers, body: try encode(payload))
            case .delete:
                response = try await api.request("DELETE", path, headers: headers)
            }
            let (data, status) = response
            switch status {
            case 200, 201:
                let ack = try decoder.decode(Ack.self, from: data)
                store.updateSyncState { SyncMerger.acknowledge(op, version: ack.version, state: &$0) }
            case 409:
                let conflict = try decoder.decode(Conflict.self, from: data)
                store.updateSync { local, state in
                    SyncMerger.resolveConflict(conflict.current, to: &local, state: &state, calendar: store.calendar)
                }
            case 410:
                store.updateSync { local, state in
                    SyncMerger.resolveGone(op, to: &local, state: &state, calendar: store.calendar)
                }
            case 412:
                // The server does not have the version we know (e.g. a reset server): forget it and
                // retry the same op as a create (If-None-Match: * / If-Match: * for deletes).
                store.updateSyncState { $0.knownVersions[op.recordID] = nil }
            default:
                throw SyncError.http(status, "odeslání")
            }
        }
    }

    private func encode(_ payload: SyncPayload) throws -> Data {
        switch payload {
        case let .session(s): return try encoder.encode(s)
        case let .postponement(p): return try encoder.encode(p)
        case let .profile(p): return try encoder.encode(p)
        }
    }

    /// Images are optional: failures leave the pictogram and are retried next sync.
    private func downloadMissingImages(_ api: API) async {
        let ids = Set(store.catalog.exercises.compactMap(\.imageAssetID))
        try? FileManager.default.createDirectory(at: AssetCache.directory, withIntermediateDirectories: true)
        for id in ids where AssetCache.data(for: id) == nil {
            guard let (data, status) = try? await api.request("GET", "/api/v1/assets/\(id)"), status == 200 else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == id.lowercased() else { continue }
            try? data.write(to: AssetCache.fileURL(for: id), options: .atomic)
        }
    }

    // MARK: Types

    private struct Ack: Decodable { let version: Int }
    private struct Conflict: Decodable { let current: SyncRecord }

    struct SyncError: Error {
        let message: String
        static func http(_ status: Int, _ what: String) -> SyncError {
            switch status {
            case 401, 403: return SyncError(message: "Server odmítl token (\(status)).")
            default: return SyncError(message: "Synchronizace (\(what)) selhala: HTTP \(status).")
            }
        }
    }

    private struct API {
        let base: URL
        let token: String
        let session: URLSession

        func request(_ method: String, _ path: String, headers: [String: String] = [:],
                     body: Data? = nil) async throws -> (Data, Int) {
            guard let url = URL(string: base.absoluteString + path) else { throw SyncError(message: "Neplatná adresa serveru.") }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
