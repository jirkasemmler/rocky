import Foundation
import Observation
import RockyCore

extension Calendar {
    /// Device time zone, Monday-first weeks, Czech locale.
    static var training: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.locale = Locale(identifier: "cs_CZ")
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }
}

/// App-wide observable state on top of `TrainingData` (settings, history, postponements).
/// Used by both the iOS and the watch app; each device keeps its own local JSON copy and
/// merges the other side's sessions via `WatchSyncService`.
@MainActor
@Observable
final class TrainingStore {
    private(set) var data: TrainingData
    /// Refreshed by `refresh()` (on foreground, after saving, once a minute on Home).
    private(set) var now: Date
    private(set) var lastError: String?

    /// Active exercise catalog: the cached server catalog, else the built-in one (D-24).
    private(set) var catalog: Catalog
    /// Server sync bookkeeping (iPhone only; the watch has no server connection).
    private(set) var syncState: SyncState

    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored private let catalogURL: URL?
    @ObservationIgnored private let syncStateURL: URL?
    @ObservationIgnored let calendar: Calendar
    /// Called after every local change (iOS: reschedule notifications, schedule a sync).
    @ObservationIgnored var onChange: ((TrainingData) -> Void)?
    /// Called when the active catalog changed (iOS: forward it to the watch).
    @ObservationIgnored var onCatalogChange: ((Catalog) -> Void)?

    /// - Parameters:
    ///   - catalogURL: where the server catalog is cached (nil = built-in only).
    ///   - syncStateURL: where the server sync state lives (nil = no server sync on this device).
    init(persistence: PersistenceStore, calendar: Calendar = .training, now: Date = Date(),
         catalogURL: URL? = nil, syncStateURL: URL? = nil) {
        self.persistence = persistence
        self.calendar = calendar
        self.now = now
        self.catalogURL = catalogURL
        self.syncStateURL = syncStateURL
        let initial: TrainingData
        if let loaded = try? persistence.load() {
            initial = loaded
        } else {
            initial = TrainingData(planStart: calendar.startOfDay(for: now))
            try? persistence.save(initial)
        }
        data = initial
        catalog = Self.loadCatalog(catalogURL) ?? .builtIn
        syncState = Self.loadJSON(SyncState.self, from: syncStateURL) ?? SyncState()
        migratePostponementDays()
    }

    private static let decoder = JSONFilePersistenceStore.makeDecoder()
    private static let encoder = JSONFilePersistenceStore.makeEncoder()

    private static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let bytes = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: bytes)
    }

    private static func loadCatalog(_ url: URL?) -> Catalog? {
        guard let catalog = loadJSON(Catalog.self, from: url), catalog.validate().isEmpty else { return nil }
        return catalog
    }

    /// Older postponements get their `day` key once (SERVER-SPEC §4.2).
    private func migratePostponementDays() {
        guard data.postponements.contains(where: { $0.day == nil }) else { return }
        for i in data.postponements.indices where data.postponements[i].day == nil {
            data.postponements[i].day = Postponement.dayKey(for: data.postponements[i].date, calendar: calendar)
        }
        try? persistence.save(data)
    }

    // MARK: Derived state

    var settings: Settings { data.settings }
    var planner: DebtPlanner { DebtPlanner(settings: data.settings, calendar: calendar) }
    var state: PlannerState { planner.state(now: now, history: data.history) }
    var sessionsNewestFirst: [Session] { data.sessions.sorted { $0.date > $1.date } }

    var progression: ProgressionAdvice {
        ProgressionAdvisor.advise(sessions: data.sessions, now: now, calendar: calendar)
    }

    var timingSuggestions: [TimingSuggestion] {
        TimingStats.suggestions(recentSessions: data.sessions, intervals: data.settings.intervals)
    }

    var weeklyMinutes: [DayMinutes] {
        TimingStats.weeklyMinutes(sessions: data.sessions, weekContaining: now, calendar: calendar)
    }

    /// The workout definition to run (active catalog).
    func workout(_ id: WorkoutID) -> Workout { catalog.workout(id) }

    /// Exercise by id for history: current catalog, then the built-in library.
    func exercise(id: String) -> Exercise? { catalog.exercise(id: id) ?? WorkoutLibrary.exercise(id: id) }

    /// Last used dumbbell weight (preselected in the preview).
    var lastWeight: DumbbellWeight {
        data.sessions.max { $0.date < $1.date }?.weight ?? .kg2
    }

    func upcomingReminders() -> [Reminder] {
        planner.upcomingReminders(now: Date(), history: data.history)
    }

    // MARK: Mutations

    func refresh(now: Date = Date()) {
        self.now = now
    }

    func save(_ session: Session) {
        // A session deleted here never comes back (e.g. a late copy from the watch).
        if syncStateURL != nil, syncState.isTombstoned(.session, session.id.uuidString) { return }
        data.upsert(session)
        noteUpsert(.session, session.id.uuidString)
        commit()
    }

    func postponeToday(_ reason: PostponeReason) {
        let today = calendar.startOfDay(for: Date())
        let day = Postponement.dayKey(for: today, calendar: calendar)
        data.postponements.removeAll { $0.dayKey(calendar: calendar) == day }
        data.postponements.append(Postponement(date: today, reason: reason, day: day))
        noteUpsert(.postponement, day)
        commit()
    }

    func cancelPostponementToday() {
        let day = Postponement.dayKey(for: Date(), calendar: calendar)
        let before = data.postponements.count
        data.postponements.removeAll { $0.dayKey(calendar: calendar) == day }
        if data.postponements.count != before, syncStateURL != nil {
            syncState.noteLocalDelete(.postponement, day)
        }
        commit()
    }

    func updateSettings(_ settings: Settings) {
        guard settings != data.settings else { return }
        data.settings = settings
        noteUpsert(.profile, SyncKeys.profileKey)
        commit()
    }

    func deleteSession(id: UUID) {
        data.sessions.removeAll { $0.id == id }
        if syncStateURL != nil { syncState.noteLocalDelete(.session, id.uuidString) }
        commit()
    }

    // MARK: Catalog

    /// Activates a newer, valid catalog (from the server or, on the watch, from the phone).
    /// Returns false if it was rejected (invalid or older than the active one).
    @discardableResult
    func applyCatalog(_ new: Catalog) -> Bool {
        guard new.validate().isEmpty, new.revision > catalog.revision || (new.revision == catalog.revision && new != catalog)
        else { return false }
        if let catalogURL, let bytes = try? Self.encoder.encode(new) {
            try? bytes.write(to: catalogURL, options: .atomic)
        }
        catalog = new
        onCatalogChange?(new)
        return true
    }

    // MARK: Server sync (used by ServerSyncService)

    /// Runs a sync step on data + sync state together and persists both. `body` returns
    /// whether the training data changed.
    func updateSync(_ body: (inout TrainingData, inout SyncState) -> Bool) {
        var newData = data
        var newState = syncState
        let dataChanged = body(&newData, &newState)
        syncState = newState
        saveSyncState()
        if dataChanged {
            data = newData
            commit()
        }
    }

    /// Changes only the sync state (status, errors).
    func updateSyncState(_ body: (inout SyncState) -> Void) {
        body(&syncState)
        saveSyncState()
    }

    private func noteUpsert(_ kind: SyncRecordKind, _ key: String) {
        guard syncStateURL != nil, syncState.serverURL != nil else { return }
        syncState.noteLocalUpsert(kind, key)
    }

    private func saveSyncState() {
        guard let syncStateURL, let bytes = try? Self.encoder.encode(syncState) else { return }
        try? bytes.write(to: syncStateURL, options: .atomic)
    }

    private func commit() {
        saveSyncState()
        do {
            try persistence.save(data)
            lastError = nil
        } catch {
            lastError = "Uložení se nepovedlo: \(error.localizedDescription)"
        }
        refresh()
        onChange?(data)
    }
}
