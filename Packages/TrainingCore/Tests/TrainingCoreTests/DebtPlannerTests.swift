import XCTest
@testable import TrainingCore

/// Default plan: Mon/Wed/Fri, reminder 19:00, latest escalation 22:30.
/// November 2026: Mon 2, Tue 3, Wed 4, Thu 5, Fri 6, Sat 7, Sun 8, Mon 9 ...
final class DebtPlannerTests: XCTestCase {
    let planner = DebtPlanner(settings: .default, calendar: T.cal)
    let start = T.date(2026, 11, 2)

    private func state(_ now: Date, _ sessions: [Session] = [], _ postponements: [Postponement] = []) -> PlannerState {
        planner.state(now: now, history: PlannerHistory(planStart: start, sessions: sessions, postponements: postponements))
    }

    private func s(_ d: Int, _ id: WorkoutID, month: Int = 11) -> Session { T.session(T.date(2026, month, d), id) }

    // MARK: Basics

    func testFirstMondayPlannedA() {
        let st = state(T.date(2026, 11, 2, 8))
        XCTAssertEqual(st.due, DueWorkout(workoutID: .a, kind: .planned, isShortened: false))
        XCTAssertFalse(st.debt.hasDebt)
        XCTAssertTrue(st.canStartWorkout)
        XCTAssertTrue(st.canPostpone)
        XCTAssertEqual(st.remindersToday.map { T.hm($0.fireDate) }, ["19:00"], "regular day: single reminder")
        XCTAssertEqual(st.remindersToday.first?.title, "Dnešní trénink: Trénink A")
    }

    func testCompletedTodayStopsRemindersAndBlocksSecondWorkout() {
        let st = state(T.date(2026, 11, 2, 20), [s(2, .a)])
        XCTAssertNil(st.due)
        XCTAssertTrue(st.completedToday)
        XCTAssertFalse(st.canStartWorkout, "max one workout per day")
        XCTAssertFalse(st.canPostpone)
        XCTAssertTrue(st.remindersToday.isEmpty)
        XCTAssertEqual(st.nextWorkoutID, .b)
    }

    func testRestDayNothingDue() {
        let st = state(T.date(2026, 11, 3, 12), [s(2, .a)])
        XCTAssertNil(st.due)
        XCTAssertFalse(st.canPostpone)
        XCTAssertTrue(st.remindersToday.isEmpty)
        XCTAssertTrue(st.canStartWorkout, "bonus workout allowed on a rest day")
    }

    func testRegularRotationABC() {
        let st = state(T.date(2026, 11, 6, 8), [s(2, .a), s(4, .b)])
        XCTAssertEqual(st.due?.workoutID, .c)
        XCTAssertEqual(state(T.date(2026, 11, 9, 8), [s(2, .a), s(4, .b), s(6, .c)]).due?.workoutID, .a)
    }

    func testIncompleteSessionDoesNotCount() {
        var aborted = s(2, .a)
        aborted.completed = false
        let st = state(T.date(2026, 11, 3, 8), [aborted])
        XCTAssertEqual(st.debt.count, 1)
    }

    // MARK: Missed -> debt -> catch-up

    func testMissedSlotBecomesCatchUpNextDayWithEscalation() {
        let st = state(T.date(2026, 11, 3, 8))
        XCTAssertEqual(st.debt.count, 1)
        XCTAssertEqual(st.debt.oldestMissedDay, T.date(2026, 11, 2))
        XCTAssertEqual(st.debt.ageDays, 1)
        XCTAssertFalse(st.debt.isLong)
        XCTAssertEqual(st.due, DueWorkout(workoutID: .a, kind: .catchUp, isShortened: false))
        XCTAssertEqual(st.remindersToday.map { T.hm($0.fireDate) }, ["19:00", "20:00", "21:00"])
        XCTAssertEqual(st.remindersToday.map(\.level), [0, 1, 2])
        XCTAssertTrue(st.remindersToday.allSatisfy(\.isCatchUp))
        XCTAssertEqual(st.remindersToday.first?.title, "Dohon: Trénink A")
    }

    func testSlotIsMissedOnlyAfter2359() {
        let st = state(T.date(2026, 11, 2, 23, 59, 59))
        XCTAssertFalse(st.debt.hasDebt)
        XCTAssertEqual(st.due?.kind, .planned)
        XCTAssertEqual(state(T.date(2026, 11, 3, 0, 0, 0)).debt.count, 1)
    }

    func testCatchUpPaysDebtAndRotationShifts() {
        let st = state(T.date(2026, 11, 4, 8), [s(3, .a)])
        XCTAssertFalse(st.debt.hasDebt)
        XCTAssertEqual(st.due, DueWorkout(workoutID: .b, kind: .planned, isShortened: false))
        let recs = planner.records(history: PlannerHistory(planStart: start, sessions: [s(3, .a)]), through: T.date(2026, 11, 4))
        XCTAssertEqual(recs[0].slotStatus, .caughtUp(on: T.date(2026, 11, 3)))
        XCTAssertTrue(recs[1].completedAsCatchUp)
    }

    func testCatchUpReplacesPlannedWorkoutOfThatDay() {
        // Mon missed, Tue nothing, Wed: the catch-up (A) is due instead of planned B.
        let wed = state(T.date(2026, 11, 4, 8))
        XCTAssertEqual(wed.due, DueWorkout(workoutID: .a, kind: .catchUp, isShortened: false))
        XCTAssertEqual(wed.debt.count, 1, "Wed slot is not missed before 23:59")
        // Doing it on Wed pays Mon, but Wed's own slot is then missed -> Thu catch-up B.
        let thu = state(T.date(2026, 11, 5, 8), [s(4, .a)])
        XCTAssertEqual(thu.debt.count, 1)
        XCTAssertEqual(thu.debt.oldestMissedDay, T.date(2026, 11, 4))
        XCTAssertEqual(thu.due, DueWorkout(workoutID: .b, kind: .catchUp, isShortened: false))
        // Thu done -> Fri planned C: the week got denser, nothing lost.
        let fri = state(T.date(2026, 11, 6, 8), [s(4, .a), s(5, .b)])
        XCTAssertEqual(fri.due, DueWorkout(workoutID: .c, kind: .planned, isShortened: false))
    }

    func testMaxOneWorkoutPerDayCountsOnce() {
        let st = state(T.date(2026, 11, 3, 8), [s(2, .a), s(2, .b)])
        XCTAssertEqual(st.nextWorkoutID, .b, "second same-day workout ignored")
        XCTAssertFalse(st.debt.hasDebt)
    }

    func testBonusWorkoutOnRestDayAdvancesRotationOnly() {
        let st = state(T.date(2026, 11, 4, 8), [s(2, .a), s(3, .b)])
        XCTAssertEqual(st.due, DueWorkout(workoutID: .c, kind: .planned, isShortened: false))
        XCTAssertFalse(st.debt.hasDebt)
    }

    // MARK: Long debt (> 2 days)

    func testDebtExactlyTwoDaysIsNotLong() {
        let wed = state(T.date(2026, 11, 4, 8))
        XCTAssertEqual(wed.debt.ageDays, 2)
        XCTAssertFalse(wed.debt.isLong)
        XCTAssertEqual(wed.due?.isShortened, false)
    }

    func testDebtOlderThanTwoDaysOffersShortenedOnlyAndCaps() {
        // Mon missed, Tue nothing, Wed missed: Thu = age 3 -> long.
        let thu = state(T.date(2026, 11, 5, 8))
        XCTAssertTrue(thu.debt.isLong)
        XCTAssertEqual(thu.debt.ageDays, 3)
        XCTAssertEqual(thu.debt.count, 1, "collapsed to one owed workout")
        XCTAssertEqual(thu.due, DueWorkout(workoutID: .a, kind: .catchUp, isShortened: true))
        XCTAssertEqual(thu.due?.roundsOverride, 2)
        XCTAssertTrue(thu.remindersToday.first!.body.contains("Zkrácená verze (2 kola)"))
        // Fri missed too: no new debt is added while long debt is open.
        let sat = state(T.date(2026, 11, 7, 8))
        XCTAssertEqual(sat.debt.count, 1)
        XCTAssertEqual(sat.debt.oldestMissedDay, T.date(2026, 11, 2))
        XCTAssertTrue(sat.due!.isShortened)
    }

    func testShortenedCatchUpClearsLongDebt() {
        var short = s(7, .a)
        short.rounds = 2
        let sun = state(T.date(2026, 11, 8, 8), [short])
        XCTAssertFalse(sun.debt.hasDebt)
        XCTAssertNil(sun.due)
        let mon = state(T.date(2026, 11, 9, 8), [short])
        XCTAssertEqual(mon.due, DueWorkout(workoutID: .b, kind: .planned, isShortened: false))
    }

    func testDebtCountTwoBeforeCollapse() {
        // Mon missed, Tue catch-up skipped, Wed: still 1; Wed missed -> Thu would be 2 but it is long by then.
        // Use Tue/Thu/Sat plan to see two concurrent debts without hitting the 2-day limit.
        var settings = Settings.default
        settings.trainingDays = [.monday, .tuesday, .wednesday]
        let p = DebtPlanner(settings: settings, calendar: T.cal)
        let st = p.state(now: T.date(2026, 11, 4, 8), history: PlannerHistory(planStart: start))
        XCTAssertEqual(st.debt.count, 2, "Mon + Tue missed")
        XCTAssertEqual(st.debt.ageDays, 2)
        XCTAssertFalse(st.debt.isLong)
    }

    // MARK: Postponing with reason

    func testIllnessClearsDebtAndPlansEasyReturn() {
        let post = [Postponement(date: T.date(2026, 11, 3, 18), reason: .illness)]
        let tue = state(T.date(2026, 11, 3, 18, 30), [], post)
        XCTAssertNil(tue.due)
        XCTAssertEqual(tue.postponedToday, .illness)
        XCTAssertFalse(tue.debt.hasDebt)
        XCTAssertTrue(tue.remindersToday.isEmpty)
        let wed = state(T.date(2026, 11, 4, 8), [], post)
        XCTAssertEqual(wed.due, DueWorkout(workoutID: .a, kind: .easyReturn, isShortened: true))
        XCTAssertFalse(wed.debt.hasDebt)
        // after the easy return, back to normal
        let fri = state(T.date(2026, 11, 6, 8), [s(4, .a)], post)
        XCTAssertEqual(fri.due, DueWorkout(workoutID: .b, kind: .planned, isShortened: false))
        let recs = planner.records(history: PlannerHistory(planStart: start, postponements: post), through: T.date(2026, 11, 4))
        XCTAssertEqual(recs[0].slotStatus, .excused(.illness))
    }

    func testInjuryOnSlotDayExcusesSlot() {
        let post = [Postponement(date: T.date(2026, 11, 2, 18), reason: .injury)]
        let tue = state(T.date(2026, 11, 3, 8), [], post)
        XCTAssertFalse(tue.debt.hasDebt)
        XCTAssertNil(tue.due)
        XCTAssertEqual(state(T.date(2026, 11, 4, 8), [], post).due?.kind, .easyReturn)
    }

    func testTravelKeepsDebtButPausesAging() {
        let post = [Postponement(date: T.date(2026, 11, 3, 10), reason: .travel)]
        let tue = state(T.date(2026, 11, 3, 12), [], post)
        XCTAssertEqual(tue.debt.count, 1, "travel does not clear debt")
        XCTAssertNil(tue.due)
        XCTAssertTrue(tue.remindersToday.isEmpty)
        let wed = state(T.date(2026, 11, 4, 8), [], post)
        XCTAssertEqual(wed.debt.ageDays, 1, "Tue excused")
        XCTAssertEqual(wed.due?.kind, .catchUp)
        // Without travel Thu would be long (age 3); with one travel day it is age 2.
        let thu = state(T.date(2026, 11, 5, 8), [], post)
        XCTAssertEqual(thu.debt.ageDays, 2)
        XCTAssertFalse(thu.debt.isLong)
        XCTAssertEqual(thu.debt.count, 2, "Wed slot missed too")
    }

    func testTravelOnPlannedDayExcusesSlotWithoutDebt() {
        let post = [Postponement(date: T.date(2026, 11, 2, 10), reason: .travel)]
        let tue = state(T.date(2026, 11, 3, 8), [], post)
        XCTAssertFalse(tue.debt.hasDebt)
        XCTAssertEqual(state(T.date(2026, 11, 4, 8), [], post).due, DueWorkout(workoutID: .a, kind: .planned, isShortened: false))
    }

    func testPostponeOnRestDayWithoutDebtIsIgnored() {
        let post = [Postponement(date: T.date(2026, 11, 3, 10), reason: .illness)]
        let wed = state(T.date(2026, 11, 4, 8), [s(2, .a)], post)
        XCTAssertEqual(wed.due, DueWorkout(workoutID: .b, kind: .planned, isShortened: false), "no easy return without a due workout")
    }

    func testCompletionWinsOverPostponementSameDay() {
        let post = [Postponement(date: T.date(2026, 11, 2, 10), reason: .illness)]
        let tue = state(T.date(2026, 11, 3, 8), [s(2, .a)], post)
        XCTAssertFalse(tue.debt.hasDebt)
        XCTAssertEqual(tue.nextWorkoutID, .b)
        XCTAssertEqual(state(T.date(2026, 11, 4, 8), [s(2, .a)], post).due?.kind, .planned)
    }

    // MARK: Reminders

    func testEscalationCappedAt2230() {
        var settings = Settings.default
        settings.reminderTime = TimeOfDay(hour: 21)
        let p = DebtPlanner(settings: settings, calendar: T.cal)
        XCTAssertEqual(p.reminderTimes(on: T.date(2026, 11, 3), escalate: true).map { T.hm($0.date) }, ["21:00", "22:00", "22:30"])
        settings.reminderTime = TimeOfDay(hour: 22)
        XCTAssertEqual(DebtPlanner(settings: settings, calendar: T.cal).reminderTimes(on: T.date(2026, 11, 3), escalate: true)
            .map { T.hm($0.date) }, ["22:00", "22:30"], "duplicates removed")
        settings.reminderTime = TimeOfDay(hour: 23)
        XCTAssertEqual(DebtPlanner(settings: settings, calendar: T.cal).reminderTimes(on: T.date(2026, 11, 3), escalate: true)
            .map { T.hm($0.date) }, ["23:00"], "set hour after the cap: only the first reminder")
        settings.reminderTime = TimeOfDay(hour: 18, minute: 45)
        settings.latestEscalation = TimeOfDay(hour: 20)
        XCTAssertEqual(DebtPlanner(settings: settings, calendar: T.cal).reminderTimes(on: T.date(2026, 11, 3), escalate: true)
            .map { T.hm($0.date) }, ["18:45", "19:45", "20:00"])
    }

    func testEscalateOnPlannedDaysSetting() {
        var settings = Settings.default
        settings.escalateOnPlannedDays = true
        let p = DebtPlanner(settings: settings, calendar: T.cal)
        let st = p.state(now: T.date(2026, 11, 2, 8), history: PlannerHistory(planStart: start))
        XCTAssertEqual(st.remindersToday.count, 3)
        XCTAssertFalse(st.remindersToday[0].isCatchUp)
    }

    func testUpcomingRemindersProjectCatchUpTomorrow() {
        // Monday 20:30, workout not done yet: remaining today none (19:00 passed),
        // tomorrow catch-up escalation starts at the set hour (AC v1.1).
        let r = planner.upcomingReminders(now: T.date(2026, 11, 2, 20, 30), history: PlannerHistory(planStart: start), horizonDays: 2)
        XCTAssertEqual(r.first?.fireDate, T.date(2026, 11, 3, 19))
        XCTAssertEqual(r.first?.isCatchUp, true)
        XCTAssertEqual(r.prefix(3).map(\.level), [0, 1, 2])
        XCTAssertEqual(Set(r.map(\.id)).count, r.count)
    }

    func testUpcomingRemindersAfterCompletion() {
        // Catch-up done Tue 19:30 -> no more reminders Tue; next is Wed planned single reminder.
        let r = planner.upcomingReminders(now: T.date(2026, 11, 3, 19, 30),
                                          history: PlannerHistory(planStart: start, sessions: [s(3, .a)]), horizonDays: 3)
        XCTAssertEqual(r.first?.fireDate, T.date(2026, 11, 4, 19))
        XCTAssertEqual(r.first?.isCatchUp, false)
        XCTAssertFalse(r.contains { T.cal.isDate($0.fireDate, inSameDayAs: T.date(2026, 11, 3)) })
    }

    func testRemindersAcrossDSTChange() {
        // DST ends Sun 25 Oct 2026 in Prague. Reminder must stay at 19:00 local time.
        let p = DebtPlanner(settings: .default, calendar: T.cal)
        let st = p.state(now: T.date(2026, 10, 26, 8), history: PlannerHistory(planStart: T.date(2026, 10, 19)))
        XCTAssertEqual(st.remindersToday.first.map { T.hm($0.fireDate) }, "19:00")
        // 19:00 CET = 18:00 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.hour, from: st.remindersToday[0].fireDate), 18)
        // Oct 19 (Mon), 21 (Wed), 23 (Fri) all missed -> debt is long by Oct 26
        XCTAssertTrue(st.debt.isLong)
    }

    // MARK: Streak & week overview

    func testStreakCountsFullWeeks() {
        let sessions = [s(2, .a), s(4, .b), s(6, .c), s(9, .a), s(11, .b), s(13, .c)]
        XCTAssertEqual(state(T.date(2026, 11, 16, 8), sessions).streakWeeks, 2)
        // current week in progress does not break it
        XCTAssertEqual(state(T.date(2026, 11, 18, 8), sessions + [s(16, .a)]).streakWeeks, 2)
        // current week complete counts immediately
        XCTAssertEqual(state(T.date(2026, 11, 20, 21), sessions + [s(16, .a), s(18, .b), s(20, .c)]).streakWeeks, 3)
    }

    func testStreakBrokenByMissedWeek() {
        let sessions = [s(2, .a), s(4, .b), s(6, .c), s(9, .a), s(13, .b), s(16, .c), s(18, .a), s(20, .b)]
        // week of 9th: Wed 11 missed, caught up? Thu 12 nothing, Fri 13 used to catch up Wed -> Fri slot missed,
        // paid Mon 16 (next week) -> week of 9th incomplete.
        XCTAssertEqual(state(T.date(2026, 11, 23, 8), sessions).streakWeeks, 0, "week 16-20 used to pay old debt")
    }

    func testCatchUpWithinSameWeekKeepsStreak() {
        // Fri 6 missed, caught up Sat 7 -> week complete.
        let sessions = [s(2, .a), s(4, .b), s(7, .c)]
        XCTAssertEqual(state(T.date(2026, 11, 9, 8), sessions).streakWeeks, 1)
        // Fri 6 missed, caught up Mon 9 -> week not complete.
        XCTAssertEqual(state(T.date(2026, 11, 10, 8), [s(2, .a), s(4, .b), s(9, .c)]).streakWeeks, 0)
    }

    func testIllnessWeekIsNeutral() {
        let sessions = [s(2, .a), s(4, .b), s(6, .c), s(16, .a), s(18, .b), s(20, .c)]
        let post = [9, 11, 13].map { Postponement(date: T.date(2026, 11, $0, 9), reason: .illness) }
        XCTAssertEqual(state(T.date(2026, 11, 23, 8), sessions, post).streakWeeks, 2)
    }

    func testPartialFirstWeekIsNeutral() {
        let p = PlannerHistory(planStart: T.date(2026, 11, 4), sessions: [s(4, .a), s(6, .b), s(9, .c), s(11, .a), s(13, .b)])
        XCTAssertEqual(planner.state(now: T.date(2026, 11, 16, 8), history: p).streakWeeks, 1)
    }

    func testWeekOverview() {
        // Mon done, Tue rest, Wed missed (today is Fri), Thu catch-up done, Fri today.
        let st = state(T.date(2026, 11, 6, 8), [s(2, .a), s(5, .b)])
        XCTAssertEqual(st.week.count, 7)
        XCTAssertEqual(st.week.map(\.weekday), Weekday.mondayFirst)
        XCTAssertEqual(st.week[0].status, .done)
        XCTAssertEqual(st.week[1].status, .rest)
        XCTAssertEqual(st.week[2].status, .caughtUpLater)
        XCTAssertEqual(st.week[3].status, .catchUpDone)
        XCTAssertEqual(st.week[4].status, .today)
        XCTAssertEqual(st.week[5].status, .rest)
        XCTAssertEqual(st.week[6].status, .rest)
        XCTAssertEqual(st.due, DueWorkout(workoutID: .c, kind: .planned, isShortened: false))
    }

    func testWeekOverviewMissedAndUpcoming() {
        let st = state(T.date(2026, 11, 3, 8))
        XCTAssertEqual(st.week[0].status, .missed)
        XCTAssertEqual(st.week[1].status, .today, "catch-up due on a rest day")
        XCTAssertEqual(st.week[2].status, .upcoming)
        XCTAssertEqual(st.week[4].status, .upcoming)
    }

    func testBeforePlanStartNothingDue() {
        let st = planner.state(now: T.date(2026, 11, 1, 12), history: PlannerHistory(planStart: start))
        XCTAssertNil(st.due)
        XCTAssertFalse(st.debt.hasDebt)
    }

    func testDeterministicReplay() {
        let h = PlannerHistory(planStart: start, sessions: [s(3, .a), s(6, .b)],
                               postponements: [Postponement(date: T.date(2026, 11, 11), reason: .travel)])
        let a = planner.state(now: T.date(2026, 11, 20, 12), history: h)
        let b = planner.state(now: T.date(2026, 11, 20, 12), history: h)
        XCTAssertEqual(a, b)
    }
}
