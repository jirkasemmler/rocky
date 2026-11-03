import Foundation
import TrainingCore

/// Plays the distinct haptic patterns from PRD 8a. Implemented per platform
/// (`PhoneHapticsService` on iOS, `WatchHapticsService` on watchOS).
@MainActor
protocol HapticsPlaying: AnyObject {
    var isEnabled: Bool { get set }
    func play(_ pattern: HapticPattern)
}
