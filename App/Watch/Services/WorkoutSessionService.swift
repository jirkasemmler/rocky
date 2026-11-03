import Foundation
import HealthKit
import Observation

/// HKWorkoutSession wrapper (watch only). Activity type: functional strength training.
/// Keeps the watch app running during the workout (timer + haptics with the wrist down) and
/// writes the finished workout to Apple Health (PRD 8a).
@MainActor
protocol WorkoutSessionServing: AnyObject {
    var heartRate: Double? { get }
    var activeEnergyKcal: Double { get }
    func requestAuthorization() async
    func start(at date: Date) async
    func pause(at date: Date)
    func resume(at date: Date)
    /// Ends and saves the workout to Health. `save == false` discards it.
    func end(at date: Date, save: Bool) async
}

@MainActor
@Observable
final class WorkoutSessionService: NSObject, WorkoutSessionServing {
    private(set) var heartRate: Double?
    private(set) var activeEnergyKcal: Double = 0
    private(set) var lastError: String?
    /// Result of the last `end(save: true)`: true = workout written to Apple Health.
    private(set) var savedToHealth: Bool?

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate)]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start(at date: Date) async {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .functionalStrengthTraining
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            heartRate = nil
            activeEnergyKcal = 0
            savedToHealth = nil
            session.startActivity(with: date)
            try await builder.beginCollection(at: date)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pause(at date: Date) { session?.pause() }

    func resume(at date: Date) { session?.resume() }

    func end(at date: Date, save: Bool) async {
        guard let session, let builder else { return }
        session.stopActivity(with: date)
        session.end()
        do {
            try await builder.endCollection(at: date)
            if save {
                let saved = try await builder.finishWorkout()
                savedToHealth = saved != nil
            } else {
                builder.discardWorkout()
            }
        } catch {
            lastError = error.localizedDescription
            if save { savedToHealth = false }
        }
        self.session = nil
        self.builder = nil
    }
}

extension WorkoutSessionService: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.lastError = message }
    }
}

extension WorkoutSessionService: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity()?.doubleValue(for: bpm)
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in
            if let hr { self.heartRate = hr }
            if let kcal { self.activeEnergyKcal = kcal }
        }
    }
}
