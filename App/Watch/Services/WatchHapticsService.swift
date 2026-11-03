import RockyCore
import WatchKit

/// Distinct wrist haptics (PRD 8a): exercise start, last 3 s, rest, round end, workout end.
@MainActor
final class WatchHapticsService: HapticsPlaying {
    var isEnabled = true

    func play(_ pattern: HapticPattern) {
        guard isEnabled else { return }
        let device = WKInterfaceDevice.current()
        switch pattern {
        case .exerciseStart: device.play(.start)
        case .countdownTick: device.play(.click)
        case .restStart: device.play(.stop)
        case .roundEnd: device.play(.notification)
        case .workoutEnd: device.play(.success)
        }
    }
}
