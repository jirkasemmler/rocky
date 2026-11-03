import HealthKit

/// Launches the watch app with a workout configuration when a workout starts on the phone
/// (`HKHealthStore.startWatchApp`). The watch then runs an HKWorkoutSession (timer with the
/// display off, record in Apple Health) even if its app was not open (PRD 8a, D-17).
@MainActor
final class WatchWorkoutLauncher {
    private let healthStore = HKHealthStore()

    /// Calls `launched` on the main actor once the watch app accepted the configuration.
    func launch(launched: @escaping @MainActor @Sendable () -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .functionalStrengthTraining
        configuration.locationType = .indoor
        healthStore.startWatchApp(with: configuration) { success, _ in
            guard success else { return }
            Task { @MainActor in launched() }
        }
    }
}
