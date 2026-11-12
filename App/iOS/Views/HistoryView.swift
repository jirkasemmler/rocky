import Charts
import SwiftUI
import RockyCore

/// PRD screen "Historie a progrese".
struct HistoryView: View {
    @Environment(TrainingStore.self) private var store

    var body: some View {
        List {
            Section("Progrese") {
                let advice = store.progression
                Text(advice.recommendation.message)
                if let avg = advice.averageDifficulty {
                    LabeledContent("Průměrná náročnost", value: String(format: "%.1f / 5", avg))
                }
            }

            if !store.timingSuggestions.isEmpty {
                Section("Časování") {
                    ForEach(Array(store.timingSuggestions.enumerated()), id: \.offset) { _, s in
                        Text(s.message)
                    }
                }
            }

            Section("Náročnost v čase") {
                let rated = store.data.sessions.filter { $0.difficulty != nil }
                if rated.isEmpty {
                    Text("Zatím žádná hodnocení.").foregroundStyle(.secondary)
                } else {
                    Chart(rated) { session in
                        LineMark(x: .value("Datum", session.date), y: .value("Náročnost", session.difficulty?.value ?? 0))
                        PointMark(x: .value("Datum", session.date), y: .value("Náročnost", session.difficulty?.value ?? 0))
                    }
                    .chartYScale(domain: 1...5)
                    .frame(height: 160)
                }
            }

            Section("Tréninky") {
                if store.sessionsNewestFirst.isEmpty {
                    Text("Zatím žádný trénink. První je nejtěžší!").foregroundStyle(.secondary)
                }
                ForEach(store.sessionsNewestFirst) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.sessionsNewestFirst[$0].id }
                    for id in ids { store.deleteSession(id: id) }
                }
            }
        }
        .navigationTitle("Historie")
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(LocalizedText.workoutName(session.workoutID)).font(.headline)
                Text(Format.shortDateTime.string(from: session.date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(session.completed ? Format.minutes(session.actualSeconds) : "nedokončeno")
                    .foregroundStyle(session.completed ? Color.primary : Color.orange)
                if let d = session.difficulty {
                    Text("náročnost \(d.value)/5").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SessionDetailView: View {
    let session: Session
    @Environment(TrainingStore.self) private var store

    /// The definition the session ran with; older sessions (built before it was stored) ran
    /// with the built-in library (SERVER-SPEC §4.2).
    private var workoutUsed: Workout { session.workout ?? WorkoutLibrary.workout(session.workoutID) }

    private func exerciseName(_ id: String) -> String {
        workoutUsed.exercises.first { $0.id == id }?.name ?? store.exercise(id: id)?.name ?? id
    }

    var body: some View {
        let summary = TimingStats.summarize(session)
        List {
            Section {
                LabeledContent("Trénink", value: LocalizedText.workoutName(session.workoutID))
                LabeledContent("Typ", value: session.kind.label)
                LabeledContent("Kola", value: Format.rounds(session.rounds))
                LabeledContent("Činky", value: session.weight.label)
                if let d = session.difficulty {
                    LabeledContent("Náročnost", value: "\(d.value)/5 · \(d.label)")
                }
                if !session.note.isEmpty {
                    Text(session.note)
                }
            }
            Section("Čas") {
                LabeledContent("Plán", value: Format.clock(summary.plannedSeconds))
                LabeledContent("Skutečnost", value: Format.clock(summary.actualSeconds))
                if let rest = summary.averageRestActual, let planned = summary.averageRestPlanned {
                    LabeledContent("Průměrná pauza", value: "\(Int(rest.rounded())) s (plán \(Int(planned)) s)")
                }
            }
            Section("Fáze") {
                ForEach(Array(session.timings.enumerated()), id: \.offset) { _, t in
                    HStack {
                        Text(t.exerciseID.map(exerciseName) ?? t.kind.label)
                        Spacer()
                        Text("\(Int(t.actualSeconds.rounded())) / \(Int(t.plannedSeconds)) s")
                            .monospacedDigit()
                            .foregroundStyle(t.endReason.isDone ? Color.secondary : Color.orange)
                    }
                    .font(.subheadline)
                }
            }
            Section("Checklist") {
                NavigationLink("Zobrazit") {
                    ChecklistView(checklist: session.checklist, workout: workoutUsed,
                                  rounds: session.rounds)
                        .navigationTitle("Checklist")
                }
            }
        }
        .navigationTitle(Format.shortDateTime.string(from: session.date))
        .navigationBarTitleDisplayMode(.inline)
    }
}
