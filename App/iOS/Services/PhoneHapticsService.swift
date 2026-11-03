import TrainingCore
import UIKit

/// iPhone haptics. Distinct patterns per PRD 8a; the watch has the stronger, wrist-based
/// equivalents in `WatchHapticsService`.
@MainActor
final class PhoneHapticsService: HapticsPlaying {
    var isEnabled = true

    private let notification = UINotificationFeedbackGenerator()
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)

    func play(_ pattern: HapticPattern) {
        guard isEnabled else { return }
        switch pattern {
        case .exerciseStart:
            heavy.impactOccurred()
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                heavy.impactOccurred()
            }
        case .countdownTick:
            light.impactOccurred()
        case .restStart:
            soft.impactOccurred()
        case .roundEnd:
            notification.notificationOccurred(.warning)
        case .workoutEnd:
            notification.notificationOccurred(.success)
        }
    }
}
