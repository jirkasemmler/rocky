import Foundation

/// Audio session policy during a workout. iOS: `AudioSessionController`.
/// watchOS: not needed (the HKWorkoutSession keeps the app running), so `nil` is passed.
@MainActor
protocol AudioSessionControlling: AnyObject {
    var onInterruption: ((_ began: Bool) -> Void)? { get set }
    func beginWorkout()
    func endWorkout()
    func beginSpeech()
    func endSpeech()
}

