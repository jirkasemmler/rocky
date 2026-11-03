import SwiftUI
import RockyCore

/// PRD screen "Souhrn": difficulty 1–5, weight 0/2/5 kg, note; planned vs. actual time.
struct SummaryView: View {
    let completed: Bool

    @Environment(TrainingStore.self) private var store
    @Environment(WorkoutController.self) private var workout
    @State private var difficulty: Difficulty?
    @State private var note = ""
    @State private var confirmDiscard = false

    var body: some View {
        @Bindable var workout = workout
        let draft = workout.makeSession(difficulty: difficulty, note: note)
        let summary = draft.map { TimingStats.summarize($0) }

        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(completed ? "Hotovo, skvělá práce!" : "Trénink ukončen předčasně",
                          systemImage: completed ? "checkmark.seal.fill" : "flag.checkered")
                        .font(.title.bold())
                        .foregroundStyle(completed ? .green : .orange)
                    if completed, store.settings.rockyLinesEnabled {
                        Text(RockyPhrasebook.line(.workoutFinished, key: UInt64(workout.sessionID.uuid.0),
                                                  address: store.settings.address))
                            .font(.headline)
                    }
                    if let draft {
                        Text("\(LocalizedText.workoutName(draft.workoutID)) · \(draft.kind.label) · \(Format.rounds(draft.rounds))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summary {
                Section("Čas") {
                    LabeledContent("Plán", value: Format.clock(summary.plannedSeconds))
                    LabeledContent("Skutečnost", value: Format.clock(summary.actualSeconds))
                    LabeledContent("Odchylka", value: deviation(summary.deviationSeconds))
                    if summary.pausedSeconds > 0 {
                        LabeledContent("Pauzy navíc", value: Format.clock(summary.pausedSeconds))
                    }
                    if summary.skippedPhases > 0 {
                        LabeledContent("Přeskočeno", value: "\(summary.skippedPhases)×")
                    }
                }
            }

            Section("Jak náročné to bylo?") {
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        let d = Difficulty(value)
                        Button {
                            difficulty = d
                        } label: {
                            Text("\(value)")
                                .font(.title.bold())
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(difficulty == d ? Color.green : Color.secondary.opacity(0.2),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(difficulty == d ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(d?.label ?? "\(value)")
                        .accessibilityIdentifier("difficulty\(value)")
                    }
                }
                if let difficulty {
                    Text(difficulty.label).foregroundStyle(.secondary)
                }
            }

            Section("Činky") {
                Picker("Váha", selection: $workout.weight) {
                    ForEach(DumbbellWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Poznámka") {
                TextField("Např. bolelo koleno, příště víc opakování…", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section("Checklist") {
                NavigationLink("Zobrazit checklist") {
                    if let plan = workout.plan {
                        ChecklistView(checklist: workout.checklist, workout: plan.workout, rounds: plan.rounds,
                                      onTogglePre: { workout.toggle($0) },
                                      onToggleExercise: { workout.toggleExercise(round: $0, exerciseIndex: $1) },
                                      onTogglePost: { workout.toggle($0) })
                            .navigationTitle("Checklist")
                    }
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Uložit").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("saveSession")

                Button("Neukládat", role: .destructive) { confirmDiscard = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                if difficulty == nil {
                    Text("Náročnost pomáhá s doporučením progrese (po 14 dnech).")
                }
            }
        }
        .navigationTitle("Souhrn")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Trénink nebude uložen.", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Neukládat", role: .destructive) { workout.reset() }
            Button("Zpět", role: .cancel) {}
        }
    }

    private func save() {
        guard let session = workout.makeSession(difficulty: difficulty, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        store.save(session)
        workout.publish(session)
        workout.reset()
    }

    private func deviation(_ seconds: TimeInterval) -> String {
        let sign = seconds >= 0 ? "+" : "−"
        return sign + Format.clock(abs(seconds))
    }
}
