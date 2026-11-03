import SwiftUI
import RockyCore

/// Watch "Běžící trénink": exercise, big countdown, round, heart rate; pause / skip.
struct WatchRunningView: View {
    @Environment(WorkoutController.self) private var workout
    @Environment(WorkoutSessionService.self) private var health
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TabView {
            timerPage
            controlsPage
        }
        .tabViewStyle(.verticalPage)
    }

    @ViewBuilder
    private var timerPage: some View {
        if let s = workout.snapshot {
            VStack(spacing: 2) {
                Text(Format.phaseTitle(s))
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                Text(isLuminanceReduced ? "\(s.displaySeconds / 60):––" : Format.clock(s.remainingInPhase))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color(s.phase?.kind))
                HStack {
                    if let round = s.round { Text("Kolo \(round)/\(s.totalRounds)") }
                    Spacer()
                    if let hr = health.heartRate {
                        Label("\(Int(hr))", systemImage: "heart.fill").foregroundStyle(.red)
                    }
                }
                .font(.footnote)
                if let next = s.nextExercise {
                    Text("Další: \(next.name)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                if s.status == .paused {
                    Text("PAUZA").font(.headline).foregroundStyle(.yellow)
                }
            }
        } else {
            ProgressView()
        }
    }

    private var controlsPage: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { workout.perform(.back) } label: { Image(systemName: "backward.end.fill") }
                Button { workout.togglePause() } label: {
                    Image(systemName: workout.isPaused ? "play.fill" : "pause.fill")
                }
                .tint(.yellow)
                Button { workout.perform(.skip) } label: { Image(systemName: "forward.end.fill") }
            }
            .font(.title2)
            Button(role: .destructive) { workout.perform(.abort) } label: {
                Label("Ukončit", systemImage: "xmark")
            }
        }
    }

    private func color(_ kind: PhaseKind?) -> Color {
        switch kind {
        case .exercise: return .green
        case .rest, .roundRest: return .cyan
        case .warmUp: return .orange
        case .stretch: return .purple
        case nil: return .white
        }
    }
}
