import SwiftUI
import RockyCore

/// Watch "Souhrn": quick difficulty 1–5 and weight, then save (synced to the phone).
struct WatchSummaryView: View {
    let completed: Bool

    @Environment(TrainingStore.self) private var store
    @Environment(WorkoutController.self) private var workout
    @Environment(WorkoutSessionService.self) private var health
    @State private var difficulty = 3

    var body: some View {
        @Bindable var workout = workout
        ScrollView {
            VStack(spacing: 8) {
                Label(completed ? "Hotovo!" : "Ukončeno", systemImage: completed ? "checkmark.seal.fill" : "flag.checkered")
                    .font(.headline)
                    .foregroundStyle(completed ? .green : .orange)
                if let saved = health.savedToHealth {
                    Label(saved ? "Uloženo do Zdraví" : "Do Zdraví se neuložilo",
                          systemImage: saved ? "heart.text.square.fill" : "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(saved ? .pink : .orange)
                }
                if health.activeEnergyKcal > 0 {
                    Text("\(Int(health.activeEnergyKcal)) kcal").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Náročnost").font(.footnote)
                Picker("Náročnost", selection: $difficulty) {
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value) · \(Difficulty(value)?.label ?? "")").tag(value)
                    }
                }
                .frame(height: 60)
                Picker("Činky", selection: $workout.weight) {
                    ForEach(DumbbellWeight.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(height: 50)
                Button("Uložit") { save() }
                    .tint(.green)
                Button("Neukládat", role: .destructive) { workout.reset() }
            }
        }
        .navigationTitle("Souhrn")
    }

    private func save() {
        guard let session = workout.makeSession(difficulty: Difficulty(difficulty), note: "") else { return }
        store.save(session)
        workout.publish(session)
        workout.reset()
    }
}
