import SwiftUI
import RockyCore

/// PRD screen "Checklist": before / during (per round & exercise) / after.
/// Exercise and round items tick automatically when an interval runs to completion; the
/// user can also tick manually. Pass `nil` callbacks for a read-only view (history).
struct ChecklistView: View {
    let checklist: Checklist
    let workout: Workout
    let rounds: Int
    var onTogglePre: ((Checklist.PreItem) -> Void)?
    var onToggleExercise: ((Int, Int) -> Void)?
    var onTogglePost: ((Checklist.PostItem) -> Void)?

    var body: some View {
        List {
            Section("Před tréninkem") {
                ForEach(Checklist.PreItem.allCases, id: \.self) { item in
                    row(item.label, checked: checklist.pre.contains(item), action: onTogglePre == nil ? nil : { onTogglePre?(item) })
                }
            }
            ForEach(1...max(rounds, 1), id: \.self) { round in
                Section {
                    ForEach(Array(workout.exercises.enumerated()), id: \.offset) { index, exercise in
                        row("\(exercise.name) · \(exercise.targetLabel)",
                            checked: checklist.exercises.contains(.init(round: round, exerciseIndex: index)),
                            action: onToggleExercise == nil ? nil : { onToggleExercise?(round, index) })
                    }
                } header: {
                    HStack {
                        Text("Kolo \(round)")
                        Spacer()
                        if checklist.rounds.contains(round) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            Section("Po tréninku") {
                ForEach(Checklist.PostItem.allCases, id: \.self) { item in
                    row(item.label, checked: checklist.post.contains(item), action: onTogglePost == nil ? nil : { onTogglePost?(item) })
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ title: String, checked: Bool, action: (() -> Void)?) -> some View {
        let content = HStack {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? .green : .secondary)
                .font(.title2)
            Text(title)
        }
        if let action {
            Button(action: action) { content }
                .foregroundStyle(.primary)
        } else {
            content
        }
    }
}
