import SwiftUI
import RockyCore

/// Watch "Start": today's workout (or debt / bonus) and a big start button.
/// Works without the phone nearby; the session syncs to the phone later.
struct WatchStartView: View {
    @Environment(TrainingStore.self) private var store
    @Environment(WorkoutController.self) private var workout

    var body: some View {
        let state = store.state
        ScrollView {
            VStack(spacing: 10) {
                if state.debt.hasDebt {
                    Label(state.debt.isLong ? "Dluh – zkrácená verze" : "Dlužíš \(Format.workouts(state.debt.count))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let due = state.due, state.canStartWorkout {
                    Text(Format.dueTitle(due)).font(.headline).multilineTextAlignment(.center)
                    Text(Format.rounds(due.roundsOverride ?? store.settings.intervals.rounds))
                        .font(.footnote).foregroundStyle(.secondary)
                    startButton(id: due.workoutID, kind: due.kind.sessionKind, rounds: due.roundsOverride)
                } else if state.completedToday {
                    Label("Hotovo", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text("Dnes volno").font(.headline)
                    startButton(id: state.nextWorkoutID, kind: .bonus, rounds: nil, label: "Bonus")
                }
                if state.streakWeeks > 0 {
                    Label("\(state.streakWeeks) týd.", systemImage: "flame.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Rocky")
    }

    private func startButton(id: WorkoutID, kind: SessionKind, rounds: Int?, label: String = "Start") -> some View {
        Button {
            workout.start(workoutID: id, intervals: store.settings.intervals, roundsOverride: rounds, kind: kind,
                          weight: store.lastWeight, pre: [])
        } label: {
            Label(label, systemImage: "play.fill")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .tint(.green)
    }
}
