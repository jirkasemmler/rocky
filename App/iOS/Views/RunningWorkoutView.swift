import SwiftUI
import TrainingCore

/// PRD screen "Běžící trénink": huge timer readable from ~2 m, round X/3, next exercise,
/// big pause / skip / back buttons; screen stays awake.
struct RunningWorkoutView: View {
    @Environment(WorkoutController.self) private var workout
    @State private var confirmEnd = false
    @State private var showChecklist = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let snapshot = workout.snapshot {
                content(snapshot)
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Ukončit trénink?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Ukončit", role: .destructive) { workout.perform(.abort) }
            Button("Pokračovat", role: .cancel) {}
        }
        .sheet(isPresented: $showChecklist) {
            NavigationStack { LiveChecklistView() }
        }
    }

    private func content(_ s: EngineSnapshot) -> some View {
        VStack(spacing: 12) {
            topBar(s)
            Spacer(minLength: 0)

            Text(Format.phaseTitle(s))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)

            if let exercise = s.phase?.exercise {
                Text(exercise.targetLabel)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text(Format.clock(s.remainingInPhase))
                .font(.system(size: 180, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(color(for: s.phase?.kind))
                .contentTransition(.numericText(countsDown: true))
                .accessibilityLabel("Zbývá \(s.displaySeconds) sekund")

            ProgressView(value: progress(s))
                .tint(color(for: s.phase?.kind))
                .scaleEffect(x: 1, y: 3)
                .padding(.horizontal)

            if let next = s.nextExercise {
                Text("Další: \(next.name)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if !workout.lastCueText.isEmpty {
                Text(workout.lastCueText)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)
            controls(s)
        }
        .padding()
        .overlay {
            if s.status == .paused {
                Text("PAUZA")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }

    private func topBar(_ s: EngineSnapshot) -> some View {
        HStack {
            if let round = s.round {
                Text("Kolo \(round)/\(s.totalRounds)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
            }
            Spacer()
            Text("Zbývá \(Format.clock(s.plannedRemaining))")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { showChecklist = true } label: {
                Image(systemName: "checklist").font(.title)
            }
            .accessibilityLabel("Checklist")
            Button { confirmEnd = true } label: {
                Image(systemName: "xmark.circle.fill").font(.title)
            }
            .accessibilityLabel("Ukončit trénink")
        }
    }

    private func controls(_ s: EngineSnapshot) -> some View {
        HStack(spacing: 16) {
            BigButton(systemImage: "backward.end.fill", label: "Zpět") { workout.perform(.back) }
            BigButton(systemImage: s.status == .paused ? "play.fill" : "pause.fill",
                      label: s.status == .paused ? "Pokračovat" : "Pauza", prominent: true) { workout.togglePause() }
            BigButton(systemImage: "forward.end.fill", label: "Přeskočit") { workout.perform(.skip) }
        }
    }

    private func progress(_ s: EngineSnapshot) -> Double {
        let total = s.elapsedInPhase + s.remainingInPhase
        return total > 0 ? min(1, s.elapsedInPhase / total) : 0
    }

    private func color(for kind: PhaseKind?) -> Color {
        switch kind {
        case .exercise: return .green
        case .rest, .roundRest: return .cyan
        case .warmUp: return .orange
        case .stretch: return .purple
        case nil: return .white
        }
    }
}

struct BigButton: View {
    let systemImage: String
    let label: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 40, weight: .bold))
                Text(label).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(prominent ? Color.green : Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Checklist sheet during a running workout.
struct LiveChecklistView: View {
    @Environment(WorkoutController.self) private var workout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let plan = workout.plan {
                ChecklistView(
                    checklist: workout.checklist,
                    workout: plan.workout,
                    rounds: plan.rounds,
                    onTogglePre: { workout.toggle($0) },
                    onToggleExercise: { workout.toggleExercise(round: $0, exerciseIndex: $1) },
                    onTogglePost: { workout.toggle($0) }
                )
            }
        }
        .navigationTitle("Checklist")
        .toolbar { Button("Hotovo") { dismiss() } }
    }
}
