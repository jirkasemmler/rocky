import HealthKit
import WatchKit

/// Receives the workout configuration when the iPhone launches the watch app via
/// `HKHealthStore.startWatchApp` (workout started on the phone, PRD 8a / D-17).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Set by `RockyWatchApp`; starts the HKWorkoutSession right away.
    @MainActor static var onWorkoutConfiguration: ((HKWorkoutConfiguration) -> Void)?

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            Self.onWorkoutConfiguration?(workoutConfiguration)
        }
    }
}
