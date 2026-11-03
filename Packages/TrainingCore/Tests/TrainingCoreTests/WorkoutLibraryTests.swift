import XCTest
@testable import TrainingCore

final class WorkoutLibraryTests: XCTestCase {
    func testThreeWorkoutsWithFourExercisesEach() {
        XCTAssertEqual(WorkoutLibrary.all.map(\.id), [.a, .b, .c])
        for w in WorkoutLibrary.all {
            XCTAssertEqual(w.exercises.count, 4, "\(w.id)")
            XCTAssertEqual(w.defaultIntervals, .default)
            XCTAssertTrue(w.name.hasPrefix("Trénink "))
        }
    }

    func testAppendixAContents() {
        XCTAssertEqual(WorkoutLibrary.workoutA.exercises.map(\.name),
                       ["Dřepy s činkami", "Kliky", "Veslování s činkou v předklonu", "Plank"])
        XCTAssertEqual(WorkoutLibrary.workoutB.exercises.map(\.name),
                       ["Výpady vzad s činkami", "Tlaky nad hlavu", "Glute bridge s činkou", "Dead bug"])
        XCTAssertEqual(WorkoutLibrary.workoutC.exercises.map(\.name),
                       ["Bulharský dřep", "Kliky s užším postavením rukou", "Rumunský mrtvý tah s činkami", "Boční plank"])
        XCTAssertEqual(WorkoutLibrary.squat.target, .reps(min: 12, max: 15))
        XCTAssertEqual(WorkoutLibrary.plank.target, .time(minSeconds: 30, maxSeconds: 45))
        XCTAssertEqual(WorkoutLibrary.sidePlank.target, .time(minSeconds: 20, maxSeconds: 30))
        XCTAssertTrue(WorkoutLibrary.sidePlank.perSide)
        XCTAssertTrue(WorkoutLibrary.bentOverRow.perSide)
    }

    func testIDsUniqueAndTipsPresent() {
        let all = WorkoutLibrary.all.flatMap(\.exercises)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        for e in all {
            XCTAssertFalse(e.techniqueTip.isEmpty, e.id)
            XCTAssertEqual(WorkoutLibrary.exercise(id: e.id), e)
        }
    }

    func testDefaultsFromPRD() {
        let iv = IntervalSettings.default
        XCTAssertEqual(iv.workSeconds, 40)
        XCTAssertEqual(iv.restSeconds, 20)
        XCTAssertEqual(iv.roundRestSeconds, 90)
        XCTAssertEqual(iv.rounds, 3)
        XCTAssertEqual(iv.warmUpSeconds, 180)
    }

    func testTargetLabels() {
        XCTAssertEqual(WorkoutLibrary.squat.targetLabel, "12–15 opakování")
        XCTAssertEqual(WorkoutLibrary.bentOverRow.targetLabel, "12 na stranu")
        XCTAssertEqual(WorkoutLibrary.plank.targetLabel, "30–45 s")
        XCTAssertEqual(WorkoutLibrary.sidePlank.targetLabel, "20–30 s na stranu")
        XCTAssertEqual(WorkoutLibrary.squat.spokenTargetLabel, "12 až 15 opakování")
        XCTAssertEqual(WorkoutLibrary.plank.spokenTargetLabel, "30 až 45 sekund")
    }

    func testRotation() {
        XCTAssertEqual(WorkoutID.a.next, .b)
        XCTAssertEqual(WorkoutID.b.next, .c)
        XCTAssertEqual(WorkoutID.c.next, .a)
    }

    func testDifficultyBounds() {
        XCTAssertNil(Difficulty(0))
        XCTAssertNil(Difficulty(6))
        XCTAssertEqual(Difficulty(3)?.value, 3)
    }
}
