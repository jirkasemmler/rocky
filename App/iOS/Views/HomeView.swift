import Charts
import SwiftUI
import TrainingCore

/// PRD screen "Home": today's workout button, the week overview, debt banner.
struct HomeView: View {
    @Environment(TrainingStore.self) private var store

    var body: some View {
        let state = store.state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(state)
                if state.debt.hasDebt {
                    DebtBannerView(debt: state.debt)
                }
                todayCard(state)
                WeekStripView(week: state.week)
                if !state.remindersToday.isEmpty, !state.completedToday {
                    remindersRow(state.remindersToday)
                }
                weeklyMinutesChart
                ForEach(Array(store.timingSuggestions.enumerated()), id: \.offset) { _, suggestion in
                    InfoCard(systemImage: "stopwatch", text: suggestion.message)
                }
                InfoCard(systemImage: "chart.line.uptrend.xyaxis", text: store.progression.recommendation.message)
            }
            .padding()
        }
        .navigationTitle("Osobní trenér")
        .refreshable { store.refresh() }
        .task {
            // Keep "today" fresh while the screen is open (e.g. across midnight).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                store.refresh()
            }
        }
    }

    private func header(_ state: PlannerState) -> some View {
        HStack {
            Text(Format.dayFormatter.string(from: store.now).capitalized)
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
            if state.streakWeeks > 0 {
                Label("\(state.streakWeeks) týd. v řadě", systemImage: "flame.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func todayCard(_ state: PlannerState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let due = state.due, state.canStartWorkout {
                Text(Format.dueTitle(due))
                    .font(.largeTitle.bold())
                let rounds = due.roundsOverride ?? store.settings.intervals.rounds
                let plan = WorkoutPlan(workout: WorkoutLibrary.workout(due.workoutID), intervals: store.settings.intervals,
                                       roundsOverride: due.roundsOverride)
                Text("\(Format.rounds(rounds)) · cca \(Format.minutes(plan.plannedDuration))\(due.isShortened ? " · zkrácená verze" : "")")
                    .foregroundStyle(.secondary)
                NavigationLink {
                    WorkoutPreviewView(workoutID: due.workoutID, kind: due.kind.sessionKind, roundsOverride: due.roundsOverride,
                                       title: Format.dueTitle(due))
                } label: {
                    Label("Začít trénink", systemImage: "play.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
            } else if state.completedToday {
                Label("Dnes máš hotovo", systemImage: "checkmark.seal.fill")
                    .font(.title.bold())
                    .foregroundStyle(.green)
                Text("Další trénink: \(LocalizedText.workoutName(state.nextWorkoutID))")
                    .foregroundStyle(.secondary)
            } else if let reason = state.postponedToday {
                Label("Odloženo: \(reason.label)", systemImage: "moon.zzz.fill")
                    .font(.title2.bold())
                Button("Zrušit odložení") { store.cancelPostponementToday() }
            } else {
                Label("Dnes je volno", systemImage: "leaf.fill")
                    .font(.title.bold())
                Text("Další trénink: \(LocalizedText.workoutName(state.nextWorkoutID))")
                    .foregroundStyle(.secondary)
                NavigationLink("Přesto si zacvičit (bonus)") {
                    WorkoutPreviewView(workoutID: state.nextWorkoutID, kind: .bonus, roundsOverride: nil,
                                       title: "Bonus: \(LocalizedText.workoutName(state.nextWorkoutID))")
                }
            }

            if state.canPostpone {
                Menu {
                    ForEach(PostponeReason.allCases, id: \.self) { reason in
                        Button(reason.label) { store.postponeToday(reason) }
                    }
                } label: {
                    Label("Odložit (nemoc, zranění, cesta)", systemImage: "calendar.badge.clock")
                }
                .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
    }

    private func remindersRow(_ reminders: [Reminder]) -> some View {
        let times = reminders.map { Format.time.string(from: $0.fireDate) }.joined(separator: ", ")
        return InfoCard(systemImage: "bell.fill", text: "Připomenutí dnes: \(times)")
    }

    private var weeklyMinutesChart: some View {
        VStack(alignment: .leading) {
            Text("Minuty tento týden").font(.headline)
            Chart(store.weeklyMinutes, id: \.day) { item in
                BarMark(
                    x: .value("Den", item.day, unit: .day),
                    y: .value("Minuty", item.minutes)
                )
                .foregroundStyle(.green)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 140)
        }
    }
}

struct DebtBannerView: View {
    let debt: DebtStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(debt.count == 1 ? "Dlužíš 1 trénink" : "Dlužíš \(debt.count) tréninky")
                    .font(.headline)
                Text(debt.isLong
                     ? "Dluh je starší než 2 dny – stačí zkrácená verze (2 kola) a jsi zpátky v plánu."
                     : "Dožeň ho dnes, ať se týden nerozpadne.")
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct WeekStripView: View {
    let week: [WeekDayOverview]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(week, id: \.day) { day in
                VStack(spacing: 6) {
                    Text(day.weekday.shortLabel)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Image(systemName: symbol(day.status))
                        .font(.title3)
                        .foregroundStyle(color(day.status))
                        .frame(height: 28)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isToday(day.status) ? Color.green.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("\(day.weekday.label): \(description(day.status))")
            }
        }
    }

    private func isToday(_ s: WeekDayOverview.Status) -> Bool {
        if case .today = s { return true }
        return false
    }

    private func symbol(_ s: WeekDayOverview.Status) -> String {
        switch s {
        case .rest: return "minus"
        case .upcoming: return "circle"
        case .today: return "circle.dotted"
        case .done: return "checkmark.circle.fill"
        case .caughtUpLater: return "arrow.uturn.forward.circle.fill"
        case .catchUpDone: return "plus.circle.fill"
        case .missed: return "xmark.circle.fill"
        case .excused: return "moon.zzz.fill"
        }
    }

    private func color(_ s: WeekDayOverview.Status) -> Color {
        switch s {
        case .done, .catchUpDone: return .green
        case .caughtUpLater: return .yellow
        case .missed: return .red
        case .today: return .primary
        default: return .secondary
        }
    }

    private func description(_ s: WeekDayOverview.Status) -> String {
        switch s {
        case .rest: return "volno"
        case .upcoming: return "naplánováno"
        case .today: return "dnes"
        case .done: return "splněno"
        case .caughtUpLater: return "dohnáno později"
        case .catchUpDone: return "dohnaný trénink"
        case .missed: return "vynecháno"
        case let .excused(reason): return "omluveno (\(reason.label))"
        }
    }
}

struct InfoCard: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}
