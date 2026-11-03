import Foundation

// MARK: - Public types

public enum DueKind: String, Sendable, Equatable, Codable {
    /// Regular slot of the weekly plan.
    case planned
    /// Mandatory catch-up of a missed slot; replaces the planned workout of the day.
    case catchUp
    /// First workout after an illness/injury postponement (shortened).
    case easyReturn

    public var sessionKind: SessionKind {
        switch self {
        case .planned: return .planned
        case .catchUp: return .catchUp
        case .easyReturn: return .easyReturn
        }
    }
}

public struct DueWorkout: Sendable, Equatable {
    public var workoutID: WorkoutID
    public var kind: DueKind
    /// Shortened 2-round version (old debt or easy return).
    public var isShortened: Bool
    /// Round override for the plan (nil = use settings).
    public var roundsOverride: Int? { isShortened ? DebtPlanner.shortenedRounds : nil }
}

public enum SlotStatus: Sendable, Equatable {
    /// Done on its own day.
    case done
    /// Missed, then paid by a catch-up on `on`.
    case caughtUp(on: Date)
    /// Missed and not (yet) caught up.
    case missed
    /// Excused by a postponement with a reason.
    case excused(PostponeReason)
}

public struct DebtStatus: Sendable, Equatable {
    /// Number of owed workouts.
    public var count: Int
    /// Day of the oldest missed slot still owed.
    public var oldestMissedDay: Date?
    /// Days the debt has been open (excluding travel-excused days).
    public var ageDays: Int
    /// Debt older than 2 days: only the shortened 2-round catch-up is offered and no further debt
    /// accumulates until it is paid.
    public var isLong: Bool

    public var hasDebt: Bool { count > 0 }
    public static let none = DebtStatus(count: 0, oldestMissedDay: nil, ageDays: 0, isLong: false)
}

/// What happened (or is planned) on one calendar day.
public struct DayRecord: Sendable, Equatable {
    public var day: Date
    public var isSlot: Bool
    /// What was due at the start of the day.
    public var due: DueWorkout?
    /// The workout completed that day (max one counts).
    public var completedWorkout: WorkoutID?
    public var completedAsCatchUp: Bool
    public var postponed: PostponeReason?
    /// Final slot status (nil for non-slot days or when the day has not ended yet).
    public var slotStatus: SlotStatus?
    public var debtAtStart: DebtStatus
}

public struct Reminder: Sendable, Equatable, Identifiable {
    public var id: String
    public var fireDate: Date
    /// 0 = at the set hour, 1 = +1 h, 2 = +2 h (capped at the latest escalation time).
    public var level: Int
    public var title: String
    public var body: String
    public var isCatchUp: Bool
}

public struct WeekDayOverview: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case rest
        case upcoming
        case today
        case done
        case caughtUpLater
        case catchUpDone
        case missed
        case excused(PostponeReason)
    }
    public var day: Date
    public var weekday: Weekday
    public var isSlot: Bool
    public var status: Status
}

/// Everything the Home screen needs.
public struct PlannerState: Sendable, Equatable {
    public var today: Date
    /// The workout to show on Home ("Dnešní trénink"). Nil = rest day or nothing due.
    public var due: DueWorkout?
    public var completedToday: Bool
    public var postponedToday: PostponeReason?
    public var debt: DebtStatus
    /// Next workout in the A/B/C rotation.
    public var nextWorkoutID: WorkoutID
    /// Max one workout per day.
    public var canStartWorkout: Bool
    /// A due workout can only be postponed with a reason.
    public var canPostpone: Bool
    public var remindersToday: [Reminder]
    /// Consecutive weeks with 3/3 slots done.
    public var streakWeeks: Int
    public var week: [WeekDayOverview]
}

public struct PlannerHistory: Sendable, Equatable {
    public var planStart: Date
    public var sessions: [Session]
    public var postponements: [Postponement]
    public init(planStart: Date, sessions: [Session] = [], postponements: [Postponement] = []) {
        self.planStart = planStart
        self.sessions = sessions
        self.postponements = postponements
    }
}

// MARK: - Planner

/// Weekly plan + catch-up ("dohánění") rules from PRD 8a.
///
/// Deterministic: the state is recomputed by replaying every day from `planStart` to today using
/// only the stored sessions and postponements. Rules:
/// - The week has slots on `settings.trainingDays` (default Mon/Wed/Fri). A slot is done only by
///   a completed workout on that day.
/// - A slot not done by 23:59 is missed and creates debt. The next day the catch-up is due; it
///   replaces that day's planned workout (max one workout per day), so a planned slot on a
///   catch-up day is itself missed and becomes the next debt: the rotation A/B/C shifts and the
///   week gets denser (rest days absorb the debt).
/// - Debt older than 2 days: debt collapses to one owed workout, only a shortened 2-round
///   version is offered and further misses do not add debt until it is paid.
/// - Postponing needs a reason. Illness/injury clear all debt and make the next workout an easy
///   (shortened) return. Travel excuses the day (its slot is not missed, debt does not age) but
///   keeps the debt.
/// - Reminders on a due day: at the set hour; on catch-up days also +1 h and +2 h, never later
///   than `latestEscalation` (22:30). No reminders once the day's workout is done.
/// - Streak: consecutive Monday-first weeks where all 3 slots were done on time or caught up
///   within the same week. Weeks with an excused slot or a partial first week are neutral.
public struct DebtPlanner: Sendable {
    public static let shortenedRounds = 2
    /// Debt older than this many days is "long".
    public static let longDebtThresholdDays = 2

    public var settings: Settings
    public var calendar: Calendar

    public init(settings: Settings, calendar: Calendar = .prague) {
        self.settings = settings
        var cal = calendar
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
    }

    // MARK: Main entry points

    public func state(now: Date, history: PlannerHistory) -> PlannerState {
        let today = calendar.startOfDay(for: now)
        let sim = simulate(history: history, through: today)
        let rec = sim.records.last(where: { $0.day == today }) ?? DayRecord(
            day: today, isSlot: isSlotDay(today, planStart: history.planStart), due: nil, completedWorkout: nil,
            completedAsCatchUp: false, postponed: nil, slotStatus: nil, debtAtStart: .none)

        let completedToday = rec.completedWorkout != nil
        let reminders = reminders(for: rec)
        let debtNow: DebtStatus = sim.debtNow

        return PlannerState(
            today: today,
            due: completedToday || rec.postponed != nil ? nil : rec.due,
            completedToday: completedToday,
            postponedToday: rec.postponed,
            debt: debtNow,
            nextWorkoutID: sim.rotation,
            canStartWorkout: !completedToday,
            canPostpone: !completedToday && rec.postponed == nil && rec.due != nil,
            remindersToday: reminders,
            streakWeeks: streak(records: sim.records, today: today),
            week: weekOverview(records: sim.records, today: today, planStart: history.planStart)
        )
    }

    /// Reminders for today and the next `horizonDays` days, projected as if nothing else gets done
    /// (re-schedule after every saved session or postponement). Only reminders after `now`.
    public func upcomingReminders(now: Date, history: PlannerHistory, horizonDays: Int = 7) -> [Reminder] {
        let today = calendar.startOfDay(for: now)
        guard let last = calendar.date(byAdding: .day, value: horizonDays, to: today) else { return [] }
        let sim = simulate(history: history, through: last)
        return sim.records
            .filter { $0.day >= today }
            .flatMap { reminders(for: $0) }
            .filter { $0.fireDate > now }
            .sorted { $0.fireDate < $1.fireDate }
    }

    /// Full day-by-day replay (useful for history UI and tests).
    public func records(history: PlannerHistory, through day: Date) -> [DayRecord] {
        simulate(history: history, through: calendar.startOfDay(for: day)).records
    }

    // MARK: Reminders

    public func reminderTimes(on day: Date, escalate: Bool) -> [(level: Int, date: Date)] {
        let start = calendar.startOfDay(for: day)
        let base = settings.reminderTime.minutesSinceMidnight
        let latest = settings.latestEscalation.minutesSinceMidnight
        let levels = escalate ? [0, 1, 2] : [0]
        var seen = Set<Int>()
        var out: [(Int, Date)] = []
        for level in levels {
            var minutes = base + level * 60
            if level > 0 { minutes = min(minutes, max(latest, base)) }
            guard !seen.contains(minutes) else { continue }
            seen.insert(minutes)
            if let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) {
                out.append((level, date))
            }
        }
        return out
    }

    private func reminders(for rec: DayRecord) -> [Reminder] {
        guard let due = rec.due, rec.completedWorkout == nil, rec.postponed == nil else { return [] }
        let isCatchUp = due.kind == .catchUp
        let escalate = isCatchUp || settings.escalateOnPlannedDays
        let name = LocalizedText.workoutName(due.workoutID)
        let suffix = due.isShortened ? " Zkrácená verze (\(DebtPlanner.shortenedRounds) kola)." : ""
        return reminderTimes(on: rec.day, escalate: escalate).map { level, date in
            let title: String
            let body: String
            switch (isCatchUp, level) {
            case (false, 0):
                title = "Dnešní trénink: \(name)"
                body = due.kind == .easyReturn ? "Lehčí návrat po pauze.\(suffix)" : "Je čas na \(name.lowercasedFirst).\(suffix)"
            case (false, _):
                title = "Připomínka: \(name)"
                body = "Dnešní trénink ještě čeká.\(suffix)"
            case (true, 0):
                title = "Dohon: \(name)"
                body = "Včera jsi trénink vynechal. Dnes nahrazuje plánovaný trénink.\(suffix)"
            case (true, 1):
                title = "Dohon stále čeká: \(name)"
                body = "Ještě je čas, stačí 20 minut.\(suffix)"
            case (true, _):
                title = "Poslední připomínka: \(name)"
                body = "Dnes naposledy. Odložit jde jen s důvodem.\(suffix)"
            }
            let id = "reminder-\(dayKey(rec.day))-\(level)"
            return Reminder(id: id, fireDate: date, level: level, title: title, body: body, isCatchUp: isCatchUp)
        }
    }

    // MARK: Simulation

    struct SimResult {
        var records: [DayRecord]
        var rotation: WorkoutID
        var debtNow: DebtStatus
    }

    private func isSlotDay(_ day: Date, planStart: Date) -> Bool {
        guard day >= calendar.startOfDay(for: planStart) else { return false }
        let wd = calendar.component(.weekday, from: day)
        return settings.trainingDays.contains { $0.rawValue == wd }
    }

    private func simulate(history: PlannerHistory, through lastDay: Date) -> SimResult {
        let startDay = calendar.startOfDay(for: history.planStart)
        var completedByDay: [Date: Session] = [:]
        for s in history.sessions.filter(\.completed).sorted(by: { $0.date < $1.date }) {
            let d = calendar.startOfDay(for: s.finishedAt ?? s.date)
            if completedByDay[d] == nil { completedByDay[d] = s } // max one workout per day counts
        }
        var postponedByDay: [Date: PostponeReason] = [:]
        for p in history.postponements.sorted(by: { $0.date < $1.date }) {
            let d = calendar.startOfDay(for: p.date)
            if postponedByDay[d] == nil { postponedByDay[d] = p.reason }
        }

        var rotation: WorkoutID = .a
        var debt: [Date] = []
        var longMode = false
        var easyReturn = false
        var travelDays = Set<Date>()
        var slotStatus: [Date: SlotStatus] = [:]
        var records: [DayRecord] = []

        func age(on day: Date) -> Int {
            guard let oldest = debt.first else { return 0 }
            let raw = calendar.dateComponents([.day], from: oldest, to: day).day ?? 0
            let excused = travelDays.filter { $0 > oldest && $0 <= day }.count
            return max(0, raw - excused)
        }

        var day = startDay
        var debtNow = DebtStatus.none
        while day <= lastDay {
            let isSlot = isSlotDay(day, planStart: history.planStart)

            let postponement = postponedByDay[day]
            // Travel-excused days do not age the debt: register before computing today's age.
            if postponement == .travel, completedByDay[day] == nil, !debt.isEmpty || isSlot {
                travelDays.insert(day)
            }

            if !debt.isEmpty, age(on: day) > DebtPlanner.longDebtThresholdDays, !longMode {
                longMode = true
                debt = [debt[0]]
            }
            let debtAtStart = DebtStatus(count: debt.count, oldestMissedDay: debt.first, ageDays: age(on: day), isLong: longMode)

            let due: DueWorkout?
            if !debt.isEmpty {
                due = DueWorkout(workoutID: rotation, kind: .catchUp, isShortened: longMode || easyReturn)
            } else if isSlot {
                due = easyReturn ? DueWorkout(workoutID: rotation, kind: .easyReturn, isShortened: true)
                                 : DueWorkout(workoutID: rotation, kind: .planned, isShortened: false)
            } else {
                due = nil
            }

            var completedWorkout: WorkoutID?
            var completedAsCatchUp = false
            var postponedApplied: PostponeReason?

            if let session = completedByDay[day] {
                completedWorkout = session.workoutID
                rotation = session.workoutID.next
                easyReturn = false
                if !debt.isEmpty {
                    let paid = debt.removeFirst()
                    slotStatus[paid] = .caughtUp(on: day)
                    completedAsCatchUp = true
                    if longMode {
                        debt.removeAll()
                        longMode = false
                    }
                } else if isSlot {
                    slotStatus[day] = .done
                }
            } else if let reason = postponement, due != nil {
                postponedApplied = reason
                if reason.clearsDebt {
                    for d in debt { slotStatus[d] = .excused(reason) }
                    debt.removeAll()
                    longMode = false
                    easyReturn = true
                }
                if isSlot { slotStatus[day] = .excused(reason) }
            }

            records.append(DayRecord(day: day, isSlot: isSlot, due: due, completedWorkout: completedWorkout,
                                     completedAsCatchUp: completedAsCatchUp, postponed: postponedApplied,
                                     slotStatus: nil, debtAtStart: debtAtStart))
            debtNow = DebtStatus(count: debt.count, oldestMissedDay: debt.first, ageDays: age(on: day), isLong: longMode && !debt.isEmpty)

            // End of day (23:59) for every day before the last simulated one.
            if day < lastDay {
                if isSlot, slotStatus[day] == nil {
                    slotStatus[day] = .missed
                    if !longMode { debt.append(day) }
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }

        // Attach final slot statuses.
        for i in records.indices where records[i].isSlot {
            records[i].slotStatus = slotStatus[records[i].day]
        }
        return SimResult(records: records, rotation: rotation, debtNow: debtNow)
    }

    // MARK: Streak & week

    private func weekStart(_ day: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
    }

    func fulfilledInWeek(_ status: SlotStatus?, slotDay: Date) -> Bool {
        switch status {
        case .done: return true
        case let .caughtUp(on): return weekStart(on) == weekStart(slotDay)
        default: return false
        }
    }

    private func streak(records: [DayRecord], today: Date) -> Int {
        let required = settings.trainingDays.count
        guard required > 0 else { return 0 }
        let byWeek = Dictionary(grouping: records.filter(\.isSlot)) { weekStart($0.day) }
        let currentWeek = weekStart(today)
        var count = 0
        // Current week counts only once it is already complete; never breaks the streak.
        if let slots = byWeek[currentWeek], slots.count == required,
           slots.allSatisfy({ fulfilledInWeek($0.slotStatus, slotDay: $0.day) }) {
            count += 1
        }
        let pastWeeks = byWeek.keys.filter { $0 < currentWeek }.sorted(by: >)
        for w in pastWeeks {
            let slots = byWeek[w] ?? []
            let excused = slots.contains { if case .excused = $0.slotStatus { return true } else { return false } }
            let nonExcusedOK = slots.allSatisfy { s in
                if case .excused = s.slotStatus { return true }
                return fulfilledInWeek(s.slotStatus, slotDay: s.day)
            }
            if slots.count == required, !excused, nonExcusedOK {
                count += 1
            } else if nonExcusedOK, excused || slots.count < required {
                continue // neutral week
            } else {
                break
            }
        }
        return count
    }

    private func weekOverview(records: [DayRecord], today: Date, planStart: Date) -> [WeekDayOverview] {
        let start = weekStart(today)
        let byDay = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return (0..<7).compactMap { offset -> WeekDayOverview? in
            guard let raw = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let day = calendar.startOfDay(for: raw)
            let wd = Weekday(rawValue: calendar.component(.weekday, from: day)) ?? .monday
            let isSlot = isSlotDay(day, planStart: planStart)
            let rec = byDay[day]
            let status: WeekDayOverview.Status
            if day > today {
                status = isSlot ? .upcoming : .rest
            } else if let rec, rec.completedWorkout != nil {
                status = rec.completedAsCatchUp ? .catchUpDone : .done
            } else if let reason = rec?.postponed {
                status = .excused(reason)
            } else if day == today {
                status = (rec?.due != nil) ? .today : .rest
            } else if isSlot {
                if case .caughtUp = rec?.slotStatus { status = .caughtUpLater } else { status = .missed }
            } else {
                status = .rest
            }
            return WeekDayOverview(day: day, weekday: wd, isSlot: isSlot, status: status)
        }
    }

    private func dayKey(_ day: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Helpers

public extension Calendar {
    /// Gregorian calendar in Europe/Prague, Monday first, Czech locale.
    static var prague: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Prague") ?? .current
        cal.locale = Locale(identifier: "cs_CZ")
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }
}

public enum LocalizedText {
    public static func workoutName(_ id: WorkoutID) -> String { "Trénink \(id.rawValue)" }
}

extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        return f.lowercased() + dropFirst()
    }
}
