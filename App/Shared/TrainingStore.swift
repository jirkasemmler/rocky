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

    @ObservationIgnored private let persistence: PersistenceStore
    @ObservationIgnored let calendar: Calendar
    /// Called after every local change (iOS: reschedule notifications).
    @ObservationIgnored var onChange: ((TrainingData) -> Void)?

    init(persistence: PersistenceStore, calendar: Calendar = .training, now: Date = Date()) {
        self.persistence = persistence
        self.calendar = calendar
        self.now = now
        if let loaded = try? persistence.load() {
            data = loaded
        } else {
            data = TrainingData(planStart: calendar.startOfDay(for: now))
            try? persistence.save(data)
        }
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
        data.upsert(session)
        commit()
    }

    func postponeToday(_ reason: PostponeReason) {
        let today = calendar.startOfDay(for: Date())
        data.postponements.removeAll { calendar.isDate($0.date, inSameDayAs: today) }
        data.postponements.append(Postponement(date: today, reason: reason))
        commit()
    }

    func cancelPostponementToday() {
        data.postponements.removeAll { calendar.isDate($0.date, inSameDayAs: Date()) }
        commit()
    }

    func updateSettings(_ settings: Settings) {
        guard settings != data.settings else { return }
        data.settings = settings
        commit()
    }

    func deleteSession(id: UUID) {
        data.sessions.removeAll { $0.id == id }
        commit()
    }

    private func commit() {
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
