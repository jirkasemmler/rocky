import XCTest
@testable import RockyCore

/// Confirmed by Jiri, 2026-11-03: a missed workout is caught up on the next day even when that
/// day is not a training day, and every day with outstanding debt escalates (set hour, +1 h,
/// +2 h, capped at 22:30). Planned days without debt escalate only with the toggle.
///
/// Calendar: Mon 2 Nov 2026 (plan start, A done), Wed 4 (B), Thu 5 rest, Fri 6, Sat 7, Sun 8, Mon 9.
final class CatchUpAnyDayTests: XCTestCase {
    let start = T.date(2026, 11, 2)
    let mondayDone = T.session(T.date(2026, 11, 2), .a)

    private func planner(_ settings: Settings = .default) -> DebtPlanner {
        DebtPlanner(settings: settings, calendar: T.cal)
    }

    private func history(_ sessions: [Session] = [], _ postponements: [Postponement] = []) -> PlannerHistory {
        PlannerHistory(planStart: start, sessions: sessions, postponements: postponements)
    }

    private func state(_ now: Date, _ sessions: [Session], settings: Settings = .default) -> PlannerState {
        planner(settings).state(now: now, history: history(sessions))
    }

    private func settings(reminder h: Int, _ m: Int = 0, toggle: Bool = false) -> Settings {
        var s = Settings.default
        s.reminderTime = TimeOfDay(hour: h, minute: m)
        s.escalateOnPlannedDays = toggle
        s.rockyLinesEnabled = false
        return s
    }

    // MARK: Skipped Wednesday → Thursday (rest day) catch-up

    func testSkippedWednesdayIsDueOnThursdayRestDay() {
        let thu = state(T.date(2026, 11, 5, 8), [mondayDone])
        XCTAssertEqual(thu.due, DueWorkout(workoutID: .b, kind: .catchUp, isShortened: false))
        XCTAssertTrue(thu.canStartWorkout)
        XCTAssertTrue(thu.canPostpone)
        XCTAssertEqual(thu.debt.count, 1)
        XCTAssertEqual(thu.debt.oldestMissedDay, T.date(2026, 11, 4))
        XCTAssertEqual(thu.week.first { $0.weekday == .thursday }?.isSlot, false, "Thursday is not a training day")
        XCTAssertEqual(thu.week.first { $0.weekday == .thursday }?.status, .today)
    }

    func testThursdayCatchUpRemindersEscalateAtSetHourPlusOnePlusTwo() {
        let thu = state(T.date(2026, 11, 5, 8), [mondayDone])
        XCTAssertEqual(thu.remindersToday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])
        XCTAssertEqual(thu.remindersToday.map(\.level), [0, 1, 2])
        XCTAssertTrue(thu.remindersToday.allSatisfy(\.isCatchUp))
        XCTAssertEqual(thu.remindersToday.map(\.title), ["Dohon: Trénink B", "Dohon stále čeká: Trénink B",
                                                        "Poslední připomínka: Trénink B"])
        XCTAssertTrue(thu.remindersToday[0].body.hasSuffix("Včera jsi trénink vynechal. Dnes máš volno, ideální den na dohnání."),
                      "functional text after the optional Rocky line")
    }

    func testThursdayEscalationCappedAt2230() {
        let at21 = state(T.date(2026, 11, 5, 8), [mondayDone], settings: settings(reminder: 21))
        XCTAssertEqual(at21.remindersToday.map { T.hm($0.fireDate) }, ["21:00", "22:00", "22:30"])
        let at22 = state(T.date(2026, 11, 5, 8), [mondayDone], settings: settings(reminder: 22))
        XCTAssertEqual(at22.remindersToday.map { T.hm($0.fireDate) }, ["22:00", "22:30"], "+2 h collapses into the cap")
        let at2245 = state(T.date(2026, 11, 5, 8), [mondayDone], settings: settings(reminder: 22, 45))
        XCTAssertEqual(at2245.remindersToday.map { T.hm($0.fireDate) }, ["22:45"], "set hour after the cap: one reminder")
    }

    func testDebtDaysEscalateEvenWithToggleOff() {
        let s = settings(reminder: 19, toggle: false)
        XCTAssertEqual(state(T.date(2026, 11, 5, 8), [mondayDone], settings: s).remindersToday.count, 3)
    }

    func testThursdayCatchUpIsRecordedAndClearsDebt() {
        let thuSession = T.session(T.date(2026, 11, 5), .b, kind: .catchUp)
        let thu = state(T.date(2026, 11, 5, 21), [mondayDone, thuSession])
        XCTAssertTrue(thu.completedToday)
        XCTAssertFalse(thu.canStartWorkout, "max one workout per day")
        XCTAssertFalse(thu.debt.hasDebt)
        XCTAssertTrue(thu.remindersToday.isEmpty)
        XCTAssertEqual(thu.week.first { $0.weekday == .wednesday }?.status, .caughtUpLater)
        XCTAssertEqual(thu.week.first { $0.weekday == .thursday }?.status, .catchUpDone)

        let records = planner().records(history: history([mondayDone, thuSession]), through: T.date(2026, 11, 6))
        XCTAssertEqual(records.first { $0.day == T.date(2026, 11, 4) }?.slotStatus, .caughtUp(on: T.date(2026, 11, 5)))
        XCTAssertTrue(records.first { $0.day == T.date(2026, 11, 5) }!.completedAsCatchUp)
        // Friday is a normal planned day again, with C (rotation shifted by the catch-up).
        let fri = state(T.date(2026, 11, 6, 8), [mondayDone, thuSession])
        XCTAssertEqual(fri.due, DueWorkout(workoutID: .c, kind: .planned, isShortened: false))
        XCTAssertEqual(fri.remindersToday.map { T.hm($0.fireDate) }, ["19:00"], "no debt, toggle off: one reminder")
    }

    // MARK: Friday planned + debt

    func testFridayPlannedDayWithDebtEscalatesAndCatchUpReplacesSlot() {
        // Wed missed, Thu nothing done.
        let fri = state(T.date(2026, 11, 6, 8), [mondayDone], settings: settings(reminder: 19))
        XCTAssertEqual(fri.due, DueWorkout(workoutID: .b, kind: .catchUp, isShortened: false))
        XCTAssertEqual(fri.debt.ageDays, 2)
        XCTAssertFalse(fri.debt.isLong, "exactly 2 days is not long")
        XCTAssertEqual(fri.remindersToday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])
        XCTAssertEqual(fri.remindersToday[0].body, "Trénink ze středy ještě čeká. Dnes nahrazuje plánovaný trénink.")

        // Friday's workout pays Wednesday; Friday's own slot becomes Saturday's catch-up.
        let friSession = T.session(T.date(2026, 11, 6), .b, kind: .catchUp)
        let sat = state(T.date(2026, 11, 7, 8), [mondayDone, friSession])
        XCTAssertEqual(sat.due, DueWorkout(workoutID: .c, kind: .catchUp, isShortened: false))
        XCTAssertEqual(sat.debt.oldestMissedDay, T.date(2026, 11, 6))
        XCTAssertEqual(sat.remindersToday.count, 3, "Saturday (rest day) with debt escalates")

        // Catch-up recorded on Saturday.
        let satSession = T.session(T.date(2026, 11, 7), .c, kind: .catchUp)
        let sun = state(T.date(2026, 11, 8, 8), [mondayDone, friSession, satSession])
        XCTAssertNil(sun.due, "Sunday: no debt, rest day")
        XCTAssertFalse(sun.debt.hasDebt)
        XCTAssertTrue(sun.remindersToday.isEmpty)
        let records = planner().records(history: history([mondayDone, friSession, satSession]), through: T.date(2026, 11, 8))
        XCTAssertEqual(records.first { $0.day == T.date(2026, 11, 6) }?.slotStatus, .caughtUp(on: T.date(2026, 11, 7)))
        XCTAssertEqual(state(T.date(2026, 11, 9, 8), [mondayDone, friSession, satSession]).due,
                       DueWorkout(workoutID: .a, kind: .planned, isShortened: false))
    }

    // MARK: Debt > 2 days → shortened, any day

    func testLongDebtShortenedOnWeekendAndRecordedOnSunday() {
        // Wed missed, Thu and Fri missed too → Sat is 3 days after Wed.
        let sat = state(T.date(2026, 11, 7, 8), [mondayDone])
        XCTAssertTrue(sat.debt.isLong)
        XCTAssertEqual(sat.debt.count, 1)
        XCTAssertEqual(sat.due, DueWorkout(workoutID: .b, kind: .catchUp, isShortened: true))
        XCTAssertEqual(sat.due?.roundsOverride, 2)
        XCTAssertEqual(sat.remindersToday.count, 3)
        XCTAssertTrue(sat.remindersToday.allSatisfy { $0.body.contains("Zkrácená verze (2 kola)") })

        let sun = state(T.date(2026, 11, 8, 8), [mondayDone])
        XCTAssertEqual(sun.due?.isShortened, true)
        XCTAssertEqual(sun.remindersToday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])

        // Shortened catch-up done on Sunday clears the whole long debt.
        let sunSession = T.session(T.date(2026, 11, 8), .b, kind: .catchUp, rounds: 2)
        let sunDone = state(T.date(2026, 11, 8, 21), [mondayDone, sunSession])
        XCTAssertFalse(sunDone.debt.hasDebt)
        XCTAssertFalse(sunDone.canStartWorkout)
        XCTAssertEqual(state(T.date(2026, 11, 9, 8), [mondayDone, sunSession]).due,
                       DueWorkout(workoutID: .c, kind: .planned, isShortened: false))
    }

    // MARK: Notifications for the next 7 days

    func testDebtCreatedAt2359IsScheduledForTomorrow() {
        // Wednesday 23:59, nothing done: today's reminders are past, Thursday's catch-up is projected.
        let upcoming = planner().upcomingReminders(now: T.date(2026, 11, 4, 23, 59), history: history([mondayDone]))
        let thursday = upcoming.filter { T.cal.isDate($0.fireDate, inSameDayAs: T.date(2026, 11, 5)) }
        XCTAssertEqual(thursday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])
        XCTAssertTrue(thursday.allSatisfy(\.isCatchUp))
        XCTAssertEqual(upcoming.first?.fireDate, T.date(2026, 11, 5, 19))
    }

    func testSevenDayProjectionCoversRestDaysWithDebt() {
        let upcoming = planner().upcomingReminders(now: T.date(2026, 11, 4, 8), history: history([mondayDone]))
        let days = Set(upcoming.map { T.cal.startOfDay(for: $0.fireDate) })
        // Wed (planned) + every following day up to Wed 11 carries the (projected) debt.
        let expected = Set((4...11).map { T.date(2026, 11, $0) })
        XCTAssertEqual(days, expected)
        for day in expected where day != T.date(2026, 11, 4) {
            let r = upcoming.filter { T.cal.isDate($0.fireDate, inSameDayAs: day) }
            XCTAssertEqual(r.count, 3, "\(day)")
            XCTAssertTrue(r.allSatisfy(\.isCatchUp))
        }
        XCTAssertEqual(upcoming.filter { T.cal.isDate($0.fireDate, inSameDayAs: T.date(2026, 11, 4)) }.count, 1)
        XCTAssertEqual(Set(upcoming.map(\.id)).count, upcoming.count, "unique notification IDs")
        XCTAssertLessThanOrEqual(upcoming.count, 60, "fits the pending-notification cap")
    }

    func testCompletingWednesdayRemovesThursdayFromProjection() {
        let wed = T.session(T.date(2026, 11, 4), .b)
        let upcoming = planner().upcomingReminders(now: T.date(2026, 11, 4, 21), history: history([mondayDone, wed]))
        XCTAssertFalse(upcoming.contains { T.cal.isDate($0.fireDate, inSameDayAs: T.date(2026, 11, 5)) })
        XCTAssertEqual(upcoming.first?.fireDate, T.date(2026, 11, 6, 19))
        XCTAssertFalse(upcoming.first!.isCatchUp)
    }

    // MARK: Planned days without debt: toggle behavior

    func testPlannedDayWithoutDebtEscalatesOnlyWithToggle() {
        let wedOff = state(T.date(2026, 11, 4, 8), [mondayDone], settings: settings(reminder: 19, toggle: false))
        XCTAssertEqual(wedOff.remindersToday.map { T.hm($0.fireDate) }, ["19:00"])
        let wedOn = state(T.date(2026, 11, 4, 8), [mondayDone], settings: settings(reminder: 19, toggle: true))
        XCTAssertEqual(wedOn.remindersToday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])
        XCTAssertFalse(wedOn.remindersToday.contains(where: \.isCatchUp))
    }

    // MARK: Bonus (D-06) and max one workout per day

    func testWorkoutOnRestDayWithDebtPaysDebtEvenIfSavedAsBonus() {
        let bonus = T.session(T.date(2026, 11, 5), .b, kind: .bonus)
        let fri = state(T.date(2026, 11, 6, 8), [mondayDone, bonus])
        XCTAssertFalse(fri.debt.hasDebt, "any completed workout on a debt day pays the debt first")
        XCTAssertEqual(fri.due?.kind, .planned)
    }

    func testBonusOnRestDayWithoutDebtOnlyAdvancesRotation() {
        let wed = T.session(T.date(2026, 11, 4), .b)
        let thuBonus = T.session(T.date(2026, 11, 5), .c, kind: .bonus)
        let thu = state(T.date(2026, 11, 5, 21), [mondayDone, wed, thuBonus])
        XCTAssertNil(thu.due)
        XCTAssertFalse(thu.debt.hasDebt)
        XCTAssertEqual(thu.nextWorkoutID, .a)
        let fri = state(T.date(2026, 11, 6, 8), [mondayDone, wed, thuBonus])
        XCTAssertEqual(fri.due, DueWorkout(workoutID: .a, kind: .planned, isShortened: false))
    }

    func testTwoWorkoutsOnCatchUpDayCountOnce() {
        // Two sessions on Friday (planned + catch-up day): only one counts, so Friday's own slot
        // is still owed on Saturday.
        let first = T.session(T.date(2026, 11, 6), .b, kind: .catchUp)
        var second = T.session(T.date(2026, 11, 6), .c)
        second.date = T.date(2026, 11, 6, 20, 30)
        second.finishedAt = T.date(2026, 11, 6, 20, 55)
        let sat = state(T.date(2026, 11, 7, 8), [mondayDone, first, second])
        XCTAssertEqual(sat.debt.count, 1)
        XCTAssertEqual(sat.debt.oldestMissedDay, T.date(2026, 11, 6))
        XCTAssertEqual(sat.due, DueWorkout(workoutID: .c, kind: .catchUp, isShortened: false))
    }
}

/// Confirmed by Jiri, 2026-11-03: the closing stretch is always exactly 2 minutes.
final class FixedStretchTests: XCTestCase {
    func testEveryPlanEndsWith120sStretch() {
        let plans = [
            WorkoutPlan(workout: WorkoutLibrary.workoutA),
            WorkoutPlan(workout: WorkoutLibrary.workoutB, roundsOverride: 2),
            WorkoutPlan(workout: WorkoutLibrary.workoutC,
                        intervals: IntervalSettings(workSeconds: 60, restSeconds: 30, roundRestSeconds: 120, rounds: 5,
                                                    warmUpSeconds: 0)),
        ]
        for plan in plans {
            XCTAssertEqual(plan.phases.last?.kind, .stretch)
            XCTAssertEqual(plan.phases.last?.duration, 120)
            XCTAssertEqual(plan.phases.filter { $0.kind == .stretch }.count, 1)
        }
        XCTAssertEqual(IntervalSettings.stretchSeconds, 120)
        XCTAssertEqual(IntervalSettings.default.stretchSeconds, 120)
    }

    func testOldStoredStretchValueIsIgnored() throws {
        let json = #"{"workSeconds":45,"restSeconds":15,"roundRestSeconds":60,"rounds":4,"warmUpSeconds":120,"stretchSeconds":600}"#
        let iv = try JSONDecoder().decode(IntervalSettings.self, from: Data(json.utf8))
        XCTAssertEqual(iv, IntervalSettings(workSeconds: 45, restSeconds: 15, roundRestSeconds: 60, rounds: 4, warmUpSeconds: 120))
        XCTAssertEqual(iv.stretchSeconds, 120)
        XCTAssertEqual(WorkoutPlan(workout: WorkoutLibrary.workoutA, intervals: iv).phases.last?.duration, 120)

        let zero = #"{"workSeconds":40,"restSeconds":20,"roundRestSeconds":90,"rounds":3,"warmUpSeconds":180,"stretchSeconds":0}"#
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA,
                               intervals: try JSONDecoder().decode(IntervalSettings.self, from: Data(zero.utf8)))
        XCTAssertEqual(plan.phases.last?.kind, .stretch, "an old 'no stretch' setting no longer removes it")
    }

    func testOldSettingsFileLoadsWithStretchField() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]
        var intervals = json["intervals"] as! [String: Any]
        intervals["stretchSeconds"] = 300
        json["intervals"] = intervals
        let s = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(s.intervals, IntervalSettings.default)
    }

    func testEncodingStillWritesFixedStretchForOlderPairedBuilds() throws {
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(IntervalSettings.default)) as! [String: Any]
        XCTAssertEqual(obj["stretchSeconds"] as? Int, 120)
    }

    func testStretchCueAndNoCountdown() {
        let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)
        let cues = VoiceCueScheduler(plan: plan).cues(forPhase: plan.phases.count - 1)
        XCTAssertEqual(cues.last?.offset, 120)
        XCTAssertEqual(cues.last?.kind, .workoutEnd)
        XCTAssertFalse(cues.contains { $0.kind == .countdown })
    }
}
