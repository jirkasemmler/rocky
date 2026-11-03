import XCTest
@testable import RockyCore

/// "Rockyho hlášky": tests assert membership, placement and determinism, not exact jokes,
/// so the phrasebook can grow without touching the tests.
final class RockyLinesTests: XCTestCase {
    let plan = WorkoutPlan(workout: WorkoutLibrary.workoutA)

    private func rendered(_ c: RockyLineCategory, address: String = "", weeks: Int? = nil) -> Set<String> {
        Set(RockyLines.templates(c).map { RockyLines.render($0, address: address, weeks: weeks) })
    }

    // MARK: Phrasebook

    func testEveryCategoryHasSeveralVariantsAndNoLeftoverPlaceholders() {
        for c in RockyLineCategory.allCases {
            let t = RockyLines.templates(c)
            XCTAssertGreaterThanOrEqual(t.count, 3, "\(c) needs variety")
            XCTAssertEqual(Set(t).count, t.count, "\(c) has duplicates")
            for line in rendered(c, address: "Jiří", weeks: 3) {
                XCTAssertFalse(line.contains("{"), line)
                XCTAssertLessThanOrEqual(line.count, 90, "keep it short enough to speak: \(line)")
            }
        }
    }

    func testCatchUpContainsTheAdrianLine() {
        XCTAssertTrue(rendered(.catchUp, address: "Jiří").contains("Vstávej, Adriano… tedy Jiří, dneska to dohnáš."))
    }

    func testNoBodyShamingVocabulary() {
        let banned = ["tlust", "tlouš", "břich", "špek", "líný", "líná", "lenoch", "kila dol", "hubn", "ostud", "trapn"]
        for c in RockyLineCategory.allCases {
            for t in RockyLines.templates(c) {
                for word in banned {
                    XCTAssertFalse(t.lowercased().contains(word), "\(c): \(t)")
                }
            }
        }
    }

    func testAddressFallbackAndCapitalization() {
        XCTAssertEqual(RockyLines.render("Jdeme, {name}.", address: ""), "Jdeme, šampione.")
        XCTAssertEqual(RockyLines.render("Jdeme, {name}.", address: "  Jiří "), "Jdeme, Jiří.")
        XCTAssertEqual(RockyLines.render("{weeks} v řadě.", address: "", weeks: 3), "3 týdny v řadě.")
    }

    func testCzechWeeksPlural() {
        XCTAssertEqual(RockyLines.weeksPhrase(1), "1 týden")
        XCTAssertEqual(RockyLines.weeksPhrase(2), "2 týdny")
        XCTAssertEqual(RockyLines.weeksPhrase(4), "4 týdny")
        XCTAssertEqual(RockyLines.weeksPhrase(5), "5 týdnů")
        XCTAssertEqual(RockyLines.weeksPhrase(12), "12 týdnů")
    }

    func testSameSeedSameLinesDifferentSeedsVary() {
        var a = RockyPhrasebook(address: "Jiří", seed: 42)
        var b = RockyPhrasebook(address: "Jiří", seed: 42)
        let seqA = (0..<20).map { _ in a.line(.exerciseChange) }
        let seqB = (0..<20).map { _ in b.line(.exerciseChange) }
        XCTAssertEqual(seqA, seqB)
        XCTAssertTrue(Set(seqA).isSubset(of: rendered(.exerciseChange, address: "Jiří")))
        XCTAssertGreaterThan(Set(seqA).count, 1)
        let firsts = Set((0..<50).map { RockyPhrasebook.line(.workoutStart, key: UInt64($0)) })
        XCTAssertGreaterThan(firsts.count, 2, "different seeds should pick different lines")
    }

    func testNeverSameLineTwiceInARow() {
        var book = RockyPhrasebook(seed: 7)
        var previous: String?
        for _ in 0..<200 {
            let line = book.line(.rest)
            XCTAssertNotEqual(line, previous)
            previous = line
        }
    }

    func testSeededGeneratorIsStable() {
        var g = SeededGenerator(seed: 0)
        // SplitMix64 reference values for seed 0.
        XCTAssertEqual(g.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(g.next(), 0x6E78_9E6A_A1B9_65F4)
    }

    // MARK: Voice cues

    private func scheduler(_ opening: RockyLinesConfig.Opening = .normal, seed: UInt64 = 1, tips: Bool = true,
                           plan: WorkoutPlan? = nil) -> VoiceCueScheduler {
        VoiceCueScheduler(plan: plan ?? self.plan,
                          config: VoiceCueConfig(techniqueTipsEnabled: tips,
                                                 rockyLines: RockyLinesConfig(seed: seed, address: "Jiří", opening: opening)))
    }

    private func flavor(_ s: VoiceCueScheduler, _ phase: Int) -> [VoiceCue] {
        s.cues(forPhase: phase).filter { $0.kind == .flavor }
    }

    func testDefaultConfigHasNoFlavor() {
        let s = VoiceCueScheduler(plan: plan)
        XCTAssertFalse(plan.phases.indices.contains { s.cues(forPhase: $0).contains { $0.kind == .flavor } })
    }

    func testFunctionalCuesUnchangedWithFlavor() {
        let plain = VoiceCueScheduler(plan: plan)
        let spiced = scheduler()
        for i in plan.phases.indices {
            XCTAssertEqual(plain.cues(forPhase: i), spiced.cues(forPhase: i).filter { $0.kind != .flavor })
        }
    }

    func testOpeningLineFollowsWarmUpCue() {
        let cues = scheduler().cues(forPhase: 0)
        XCTAssertEqual(cues[0].kind, .warmUpStart, "functional cue first")
        XCTAssertEqual(cues[1].kind, .flavor)
        XCTAssertEqual(cues[1].offset, 0)
        XCTAssertTrue(rendered(.workoutStart, address: "Jiří").contains(cues[1].text))
        XCTAssertNil(cues[1].haptic)
    }

    func testOpeningForCatchUpAndShortened() {
        XCTAssertTrue(rendered(.catchUp, address: "Jiří").contains(flavor(scheduler(.catchUp), 0)[0].text))
        let short = WorkoutPlan(workout: WorkoutLibrary.workoutA, roundsOverride: 2)
        XCTAssertTrue(rendered(.shortened, address: "Jiří").contains(flavor(scheduler(.shortened, plan: short), 0)[0].text))
    }

    func testExerciseChangeOnEverySecondExercise() {
        let s = scheduler()
        for phase in plan.phases where phase.kind == .exercise {
            let lines = flavor(s, phase.index)
            if phase.exerciseIndex! % 2 == 1 {
                XCTAssertEqual(lines.count, 1)
                XCTAssertTrue(rendered(.exerciseChange, address: "Jiří").contains(lines[0].text))
                XCTAssertEqual(s.cues(forPhase: phase.index).first?.kind, .exerciseStart, "exercise name stays first")
            } else {
                XCTAssertTrue(lines.isEmpty)
            }
        }
    }

    func testRestLinesOnlyWhereNoTechniqueTip() {
        let s = scheduler()
        var withLine = 0
        for phase in plan.phases where phase.kind == .rest {
            let cues = s.cues(forPhase: phase.index)
            let hasTip = cues.contains { $0.kind == .techniqueTip }
            let lines = cues.filter { $0.kind == .flavor }
            XCTAssertEqual(lines.isEmpty, hasTip, "phase \(phase.index)")
            if let line = lines.first {
                withLine += 1
                XCTAssertTrue(rendered(.rest, address: "Jiří").contains(line.text))
                XCTAssertEqual(cues.first?.kind, .restStart)
            }
        }
        XCTAssertGreaterThan(withLine, 0, "later rounds get rest lines")
        // With tips off, every rest gets one.
        let noTips = scheduler(tips: false)
        for phase in plan.phases where phase.kind == .rest {
            XCTAssertEqual(flavor(noTips, phase.index).count, 1)
        }
    }

    func testLastRoundLineOnlyBeforeLastRound() {
        let s = scheduler()
        let roundRests = plan.phases.filter { $0.kind == .roundRest }
        XCTAssertEqual(roundRests.count, 2)
        XCTAssertTrue(flavor(s, roundRests[0].index).isEmpty)
        let last = flavor(s, roundRests[1].index)
        XCTAssertEqual(last.count, 1)
        XCTAssertTrue(rendered(.lastRound, address: "Jiří").contains(last[0].text))
        XCTAssertEqual(s.cues(forPhase: roundRests[1].index).first?.kind, .roundEnd)
    }

    func testFinishedLineAfterWorkoutEnd() {
        let s = scheduler()
        let cues = s.cues(forPhase: plan.phases.count - 1)
        XCTAssertEqual(cues.suffix(2).map(\.kind), [.workoutEnd, .flavor])
        XCTAssertTrue(rendered(.workoutFinished, address: "Jiří").contains(cues.last!.text))
    }

    func testFlavorCuesAreDeterministicPerSeed() {
        let a = scheduler(seed: 99), b = scheduler(seed: 99)
        for i in plan.phases.indices {
            XCTAssertEqual(a.cues(forPhase: i), b.cues(forPhase: i))
        }
    }

    // MARK: Reminders, Home, settings

    private let start = T.date(2026, 11, 2)

    private func plannerState(_ now: Date, settings: Settings = .default) -> PlannerState {
        DebtPlanner(settings: settings, calendar: T.cal).state(now: now, history: PlannerHistory(planStart: start))
    }

    func testCatchUpReminderGetsRockyLineButKeepsFunctionalText() {
        var settings = Settings.default
        settings.address = "Jiří"
        let st = plannerState(T.date(2026, 11, 3, 8), settings: settings)
        let first = st.remindersToday.first!
        XCTAssertEqual(first.title, "Dohon: Trénink A")
        XCTAssertTrue(rendered(.catchUp, address: "Jiří").contains { first.body.hasPrefix($0 + " ") }, first.body)

        settings.rockyLinesEnabled = false
        let plain = plannerState(T.date(2026, 11, 3, 8), settings: settings).remindersToday.first!
        XCTAssertTrue(first.body.hasSuffix(plain.body))
        XCTAssertFalse(rendered(.catchUp, address: "Jiří").contains { plain.body.contains($0) })
    }

    func testShortenedReminderUsesShortenedLine() {
        let body = plannerState(T.date(2026, 11, 5, 8)).remindersToday.first!.body
        XCTAssertTrue(body.contains("Zkrácená verze (2 kola)"))
        XCTAssertTrue(rendered(.shortened).contains { body.hasPrefix($0 + " ") }, body)
    }

    func testPlannedReminderHasNoFlavor() {
        let st = plannerState(T.date(2026, 11, 2, 8))
        XCTAssertEqual(st.remindersToday.first?.title, "Dnešní trénink: Trénink A")
        let body = st.remindersToday.first!.body
        XCTAssertFalse(RockyLineCategory.allCases.contains { c in rendered(c).contains { body.contains($0) } })
    }

    func testHomeLine() {
        let catchUp = plannerState(T.date(2026, 11, 3, 8))
        XCTAssertTrue(rendered(.catchUp).contains(RockyLines.homeLine(state: catchUp, day: catchUp.today, address: "")!))
        let shortened = plannerState(T.date(2026, 11, 5, 8))
        XCTAssertTrue(rendered(.shortened).contains(RockyLines.homeLine(state: shortened, day: shortened.today, address: "")!))
        var streak = plannerState(T.date(2026, 11, 2, 8))
        streak.due = nil
        streak.streakWeeks = 3
        let line = RockyLines.homeLine(state: streak, day: streak.today, address: "Jiří")!
        XCTAssertTrue(rendered(.streak, address: "Jiří", weeks: 3).contains(line))
        XCTAssertTrue(line.contains("3 týdny"))
        // Same day → same line (no flicker on refresh).
        XCTAssertEqual(line, RockyLines.homeLine(state: streak, day: streak.today, address: "Jiří"))
        let regular = plannerState(T.date(2026, 11, 2, 8))
        XCTAssertNil(RockyLines.homeLine(state: regular, day: regular.today, address: ""))
    }

    func testSettingsDefaultsAndBackwardCompatibleDecoding() throws {
        XCTAssertTrue(Settings.default.rockyLinesEnabled, "Rockyho hlášky are on by default")
        XCTAssertEqual(Settings.default.address, "")
        // Settings saved by a build without the Rocky fields still load.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]
        json.removeValue(forKey: "rockyLinesEnabled")
        json.removeValue(forKey: "address")
        json["speechRate"] = 0.6
        let old = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.rockyLinesEnabled)
        XCTAssertEqual(old.speechRate, 0.6)
        var custom = Settings.default
        custom.rockyLinesEnabled = false
        custom.address = "Jiří"
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(custom)), custom)
    }
}
