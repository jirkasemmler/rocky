import SwiftUI
import RockyCore

/// PRD screen "Náhled tréninku": exercises, intervals, weight, pre-workout checklist.
struct WorkoutPreviewView: View {
    let workoutID: WorkoutID
    let kind: SessionKind
    let roundsOverride: Int?
    let title: String

    @Environment(TrainingStore.self) private var store
    @Environment(WorkoutController.self) private var workout
    @State private var intervals: IntervalSettings = .default
    @State private var weight: DumbbellWeight = .kg2
    @State private var pre: Set<Checklist.PreItem> = []
    @State private var didLoad = false

    private var definition: Workout { WorkoutLibrary.workout(workoutID) }
    private var plan: WorkoutPlan { WorkoutPlan(workout: definition, intervals: intervals, roundsOverride: roundsOverride) }

    var body: some View {
        List {
            Section {
                LabeledContent("Délka", value: "cca \(Format.minutes(plan.plannedDuration))")
                LabeledContent("Kola", value: Format.rounds(plan.rounds) + (roundsOverride != nil ? " (zkráceno)" : ""))
            }

            Section("Rozcvička") {
                Text(WorkoutLibrary.warmUpDescription).font(.subheadline)
            }

            Section("Cviky") {
                ForEach(definition.exercises) { exercise in
                    NavigationLink {
                        ExerciseDetailView(exercise: exercise)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ExerciseImageView(exercise: exercise, height: 64)
                                .frame(width: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(exercise.name).font(.headline)
                                    Spacer()
                                    Text(exercise.targetLabel).foregroundStyle(.secondary)
                                }
                                Text(exercise.techniqueTip).font(.footnote).foregroundStyle(.secondary)
                                Text(exercise.equipment.label).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("exercise-\(exercise.id)")
                }
            }

            Section("Intervaly") {
                Stepper("Cvik: \(intervals.workSeconds) s", value: $intervals.workSeconds, in: 20...90, step: 5)
                Stepper("Pauza: \(intervals.restSeconds) s", value: $intervals.restSeconds, in: 10...60, step: 5)
                Stepper("Pauza mezi koly: \(intervals.roundRestSeconds) s", value: $intervals.roundRestSeconds, in: 30...180, step: 15)
                if roundsOverride == nil {
                    Stepper("Kola: \(intervals.rounds)", value: $intervals.rounds, in: 1...5)
                }
            }

            Section("Činky") {
                Picker("Váha", selection: $weight) {
                    ForEach(DumbbellWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Před tréninkem") {
                ForEach([Checklist.PreItem.water, .dumbbells, .mat], id: \.self) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { pre.contains(item) },
                        set: { on in if on { pre.insert(item) } else { pre.remove(item) } }
                    ))
                }
                Text("„Rozcvička hotová“ se odškrtne sama po rozcvičce.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    workout.start(workoutID: workoutID, intervals: intervals, roundsOverride: roundsOverride, kind: kind,
                                  weight: weight, pre: pre)
                } label: {
                    Label("Spustit", systemImage: "play.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("startWorkout")
            }
        }
        .navigationTitle(title)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            intervals = store.settings.intervals
            weight = store.lastWeight
        }
    }
}
