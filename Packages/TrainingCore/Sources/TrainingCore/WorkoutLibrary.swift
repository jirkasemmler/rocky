import Foundation

/// The three preset workouts from PRD Appendix A (3 rounds, 3 min warm-up, short stretch).
public enum WorkoutLibrary {
    public static let warmUpDescription =
        "Krouž rameny a pažemi, zakruž boky, pár lehkých dřepů a poskoky na místě."
    public static let stretchDescription =
        "Protáhni přední a zadní stranu stehen, hýždě, hrudník a ramena. Dýchej klidně."

    // MARK: Workout A

    public static let squat = Exercise(
        id: "squat", name: "Dřepy s činkami",
        techniqueTip: "Váha na patách, kolena ve směru špiček, záda rovná.",
        target: .reps(min: 12, max: 15), equipment: .dumbbells)

    public static let pushUp = Exercise(
        id: "push-up", name: "Kliky",
        techniqueTip: "Tělo drž v jedné linii, lokty asi čtyřicet pět stupňů od těla.",
        target: .reps(min: 8, max: 12), equipment: .bodyweight)

    public static let bentOverRow = Exercise(
        id: "bent-over-row", name: "Veslování s činkou v předklonu",
        techniqueTip: "Záda rovná, táhni loket podél těla směrem k boku.",
        target: .reps(min: 12, max: 12), equipment: .dumbbells, perSide: true)

    public static let plank = Exercise(
        id: "plank", name: "Plank",
        techniqueTip: "Zpevni břicho i hýždě a nepropadej se v bedrech.",
        target: .time(minSeconds: 30, maxSeconds: 45), equipment: .bodyweight)

    // MARK: Workout B

    public static let reverseLunge = Exercise(
        id: "reverse-lunge", name: "Výpady vzad s činkami",
        techniqueTip: "Krok vzad, přední koleno nad kotníkem, trup vzpřímeně. Střídej nohy.",
        target: .reps(min: 10, max: 10), equipment: .dumbbells, perSide: true, switchesSideMidway: false)

    public static let overheadPress = Exercise(
        id: "overhead-press", name: "Tlaky nad hlavu",
        techniqueTip: "Zpevni břicho, neprohýbej se v zádech a nahoře propni paže.",
        target: .reps(min: 10, max: 12), equipment: .dumbbells)

    public static let gluteBridge = Exercise(
        id: "glute-bridge", name: "Glute bridge s činkou",
        techniqueTip: "Zatlač patami do země, nahoře stiskni hýždě, bedra neprohýbej.",
        target: .reps(min: 15, max: 15), equipment: .dumbbells)

    public static let deadBug = Exercise(
        id: "dead-bug", name: "Dead bug",
        techniqueTip: "Bedra přitlač k podložce a střídej strany pomalu a pod kontrolou.",
        target: .reps(min: 10, max: 10), equipment: .bodyweight, perSide: true, switchesSideMidway: false)

    // MARK: Workout C

    public static let bulgarianSplitSquat = Exercise(
        id: "bulgarian-split-squat", name: "Bulharský dřep",
        techniqueTip: "Zadní noha na židli, váha na přední noze, jdi kolmo dolů.",
        target: .reps(min: 8, max: 10), equipment: .dumbbells, perSide: true)

    public static let closeGripPushUp = Exercise(
        id: "close-grip-push-up", name: "Kliky s užším postavením rukou",
        techniqueTip: "Dlaně pod rameny, lokty veď těsně podél těla.",
        target: .reps(min: 8, max: 12), equipment: .bodyweight)

    public static let romanianDeadlift = Exercise(
        id: "romanian-deadlift", name: "Rumunský mrtvý tah s činkami",
        techniqueTip: "Boky posílej dozadu, záda rovná, činky kloužou podél nohou.",
        target: .reps(min: 12, max: 15), equipment: .dumbbells)

    public static let sidePlank = Exercise(
        id: "side-plank", name: "Boční plank",
        techniqueTip: "Tělo v jedné linii, boky drž nahoře.",
        target: .time(minSeconds: 20, maxSeconds: 30), equipment: .bodyweight, perSide: true)

    // MARK: Workouts

    public static let workoutA = Workout(
        id: .a, name: "Trénink A",
        exercises: [squat, pushUp, bentOverRow, plank])

    public static let workoutB = Workout(
        id: .b, name: "Trénink B",
        exercises: [reverseLunge, overheadPress, gluteBridge, deadBug])

    public static let workoutC = Workout(
        id: .c, name: "Trénink C",
        exercises: [bulgarianSplitSquat, closeGripPushUp, romanianDeadlift, sidePlank])

    public static let all: [Workout] = [workoutA, workoutB, workoutC]

    public static func workout(_ id: WorkoutID) -> Workout {
        switch id {
        case .a: return workoutA
        case .b: return workoutB
        case .c: return workoutC
        }
    }

    public static func exercise(id: String) -> Exercise? {
        all.lazy.flatMap(\.exercises).first { $0.id == id }
    }
}
