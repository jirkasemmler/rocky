import XCTest
@testable import TrainingCore

final class VoiceCueSchedulerTests: XCTestCase {
    let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)

    func testAnnouncesNextExerciseBeforeStartThenCountsDown() {
        let s = VoiceCueScheduler(plan: plan)
        let rest = plan.phases[2] // rest before push-ups (20 s)
        let cues = s.cues(forPhase: rest.index)
        XCTAssertEqual(cues.first?.kind, .restStart)
        XCTAssertEqual(cues.first?.text, "Pauza.")
        let announce = cues.first { $0.kind == .announceNext }!
        XCTAssertEqual(announce.offset, 14, "6 s before the exercise starts")
        XCTAssertEqual(announce.text, "Další cvik: Kliky, 8 až 12 opakování.")
        let countdown = cues.filter { $0.kind == .countdown }
        XCTAssertEqual(countdown.map(\.offset), [17, 18, 19])
        XCTAssertEqual(countdown.map(\.text), ["tři", "dva", "jedna"])
        XCTAssertTrue(countdown.allSatisfy { $0.haptic == .countdownTick })
    }

    func testAnnounceLeadIsConfigurable() {
        let s = VoiceCueScheduler(plan: plan, config: VoiceCueConfig(announceLeadSeconds: 3))
        let announce = s.cues(forPhase: 2).first { $0.kind == .announceNext }!
        XCTAssertEqual(announce.offset, 17, "literal PRD reading: 3 s before start")
    }

    func testExerciseStartCues() {
        let s = VoiceCueScheduler(plan: plan)
        XCTAssertEqual(s.cues(forPhase: 1).first?.text, "Začínáme. Dřepy s činkami.")
        XCTAssertEqual(s.cues(forPhase: 3).first?.text, "Změna cviku. Kliky.")
        XCTAssertEqual(s.cues(forPhase: 3).first?.haptic, .exerciseStart)
        // exercise phases also count down into the rest
        XCTAssertEqual(s.cues(forPhase: 1).filter { $0.kind == .countdown }.map(\.offset), [37, 38, 39])
    }

    func testRoundEndAndWorkoutEnd() {
        let s = VoiceCueScheduler(plan: plan)
        let roundRest = plan.phases.first { $0.kind == .roundRest }!
        let first = s.cues(forPhase: roundRest.index).first!
        XCTAssertEqual(first.kind, .roundEnd)
        XCTAssertEqual(first.text, "Konec kola 1. Pauza 90 sekund.")
        XCTAssertEqual(first.haptic, .roundEnd)

        let stretch = plan.phases.last!
        let stretchCues = s.cues(forPhase: stretch.index)
        XCTAssertTrue(stretchCues.first!.text.hasPrefix("Konec kola 3. Teď protažení."))
        XCTAssertEqual(stretchCues.last?.kind, .workoutEnd)
        XCTAssertEqual(stretchCues.last?.text, "Konec tréninku. Skvělá práce!")
        XCTAssertEqual(stretchCues.last?.offset, stretch.duration)
        XCTAssertFalse(stretchCues.contains { $0.kind == .countdown }, "no countdown in stretch")
    }

    func testWarmUpCues() {
        let s = VoiceCueScheduler(plan: plan)
        let cues = s.cues(forPhase: 0)
        XCTAssertEqual(cues.first?.kind, .warmUpStart)
        XCTAssertTrue(cues.first!.text.hasPrefix("Rozcvička, 3 minuty."))
        XCTAssertEqual(cues.first { $0.kind == .announceNext }?.offset, 174)
        XCTAssertEqual(cues.first { $0.kind == .techniqueTip }?.text, "Tip: " + WorkoutLibrary.squat.techniqueTip)
    }

    func testTipsOnlyInFirstRoundAndCanBeDisabled() {
        let on = VoiceCueScheduler(plan: plan)
        let tips = on.allCues.filter { $0.kind == .techniqueTip }
        XCTAssertEqual(tips.count, 4, "one tip per exercise, first round only")
        let off = VoiceCueScheduler(plan: plan, config: VoiceCueConfig(techniqueTipsEnabled: false))
        XCTAssertTrue(off.allCues.filter { $0.kind == .techniqueTip }.isEmpty)
        let every = VoiceCueScheduler(plan: plan, config: VoiceCueConfig(tipsOnlyFirstRound: false))
        // round rests (90 s) also get tips; short rests too
        XCTAssertEqual(every.allCues.filter { $0.kind == .techniqueTip }.count, 12)
    }

    func testTipFitsBeforeAnnouncement() {
        let s = VoiceCueScheduler(plan: plan)
        for phaseCues in s.cuesByPhase {
            if let tip = phaseCues.first(where: { $0.kind == .techniqueTip }),
               let ann = phaseCues.first(where: { $0.kind == .announceNext }) {
                XCTAssertLessThanOrEqual(tip.offset + 6, ann.offset)
                XCTAssertGreaterThanOrEqual(tip.offset, 2)
            }
        }
    }

    func testSwitchSideOnlyForOneSideThenOther() {
        let s = VoiceCueScheduler(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA))
        let rowPhase = s.plan.phases.first { $0.exercise?.id == "bent-over-row" }!
        let sw = s.cues(forPhase: rowPhase.index).first { $0.kind == .switchSide }
        XCTAssertEqual(sw?.offset, 20)
        XCTAssertEqual(sw?.text, "Změna strany.")
        let squatPhase = s.plan.phases.first { $0.exercise?.id == "squat" }!
        XCTAssertNil(s.cues(forPhase: squatPhase.index).first { $0.kind == .switchSide })

        let b = VoiceCueScheduler(plan: WorkoutPlan(workout: WorkoutLibrary.workoutB))
        XCTAssertTrue(b.allCues.filter { $0.kind == .switchSide }.isEmpty, "lunges and dead bug alternate")
        let c = VoiceCueScheduler(plan: WorkoutPlan(workout: WorkoutLibrary.workoutC))
        XCTAssertEqual(c.allCues.filter { $0.kind == .switchSide }.count, 6, "bulgarian + side plank x 3 rounds")
    }

    func testTimelineSortedAndCuesSortedWithinPhase() {
        let s = VoiceCueScheduler(plan: plan)
        let times = s.timeline().map(\.time)
        XCTAssertEqual(times, times.sorted())
        for cues in s.cuesByPhase {
            XCTAssertEqual(cues.map(\.offset), cues.map(\.offset).sorted())
        }
        XCTAssertEqual(Set(s.allCues.map(\.id)).count, s.allCues.count, "ids unique")
    }

    func testNoCueOverlapsCountdownOrAnnouncement() {
        // Nothing else is scheduled inside the countdown window of a phase.
        let s = VoiceCueScheduler(plan: plan)
        for (i, cues) in s.cuesByPhase.enumerated() {
            let d = plan.phases[i].duration
            let inWindow = cues.filter { $0.offset > d - 3.5 && $0.offset < d && $0.kind != .countdown }
            XCTAssertTrue(inWindow.isEmpty, "phase \(i): \(inWindow.map(\.kind))")
        }
    }

    func testCuesInRange() {
        let s = VoiceCueScheduler(plan: plan)
        let got = s.cues(forPhase: 2, from: -1, through: 0)
        XCTAssertEqual(got.map(\.kind), [.restStart])
        XCTAssertEqual(s.cues(forPhase: 2, from: 16.5, through: 18).map(\.text), ["tři", "dva"])
        XCTAssertTrue(s.cues(forPhase: 999).isEmpty)
    }

    func testCzechPhrases() {
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(90), "90 sekund")
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(60), "jedna minuta")
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(120), "dvě minuty")
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(180), "3 minuty")
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(300), "5 minut")
        XCTAssertEqual(VoiceCueScheduler.secondsPhrase(3), "3 sekundy")
    }

    func testShortPhasesDoNotProduceNegativeOffsets() {
        let iv = IntervalSettings(workSeconds: 5, restSeconds: 2, roundRestSeconds: 0, rounds: 1, warmUpSeconds: 0, stretchSeconds: 0)
        let s = VoiceCueScheduler(plan: WorkoutPlan(workout: WorkoutLibrary.workoutA, intervals: iv))
        XCTAssertTrue(s.allCues.allSatisfy { $0.offset >= 0 })
        for (i, cues) in s.cuesByPhase.enumerated() {
            XCTAssertTrue(cues.allSatisfy { $0.offset <= s.plan.phases[i].duration })
        }
    }
}
