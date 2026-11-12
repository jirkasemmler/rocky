import Foundation

/// Source of the current time. Inject a manual one in tests.
public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

/// Manually driven time source for tests and previews.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(_ start: Date) { current = start }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public func advance(by seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
    public func set(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

public enum EngineStatus: String, Sendable, Equatable, Codable {
    case idle, running, paused, finished, aborted
}

public enum EngineEvent: Sendable, Equatable {
    case started(at: Date)
    case phaseStarted(Phase, at: Date)
    case phaseEnded(PhaseTiming)
    case paused(at: Date)
    case resumed(at: Date)
    case finished(at: Date)
    case aborted(at: Date)
}

/// Read-only view of the engine for UI.
public struct EngineSnapshot: Sendable, Equatable {
    public var status: EngineStatus
    public var phase: Phase?
    public var phaseIndex: Int
    public var phaseCount: Int
    public var elapsedInPhase: TimeInterval
    public var remainingInPhase: TimeInterval
    public var round: Int?
    public var totalRounds: Int
    public var currentExercise: Exercise?
    public var nextExercise: Exercise?
    /// Wall-clock time since start (including pauses).
    public var totalElapsed: TimeInterval
    /// Planned seconds remaining (current phase remainder + all later phases).
    public var plannedRemaining: TimeInterval

    /// Whole seconds to display on the big timer (rounded up, so "1" shows until 0).
    public var displaySeconds: Int { Int(remainingInPhase.rounded(.up)) }
}

/// Deterministic workout state machine.
///
/// Time accuracy comes from timestamps, never from counting ticks: the current phase
/// position is always `now - phaseStart - pausedTime`, and phase boundaries are computed
/// exactly (`phaseStart + paused + duration`) so late or missing `update` calls (e.g. app
/// suspended) do not drift. Call `update(at:)` as often as you like; it is idempotent.
public struct WorkoutEngine: Sendable {
    public let plan: WorkoutPlan
    public private(set) var status: EngineStatus = .idle
    public private(set) var phaseIndex: Int = 0
    public private(set) var timings: [PhaseTiming] = []
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?

    private var phaseStartedAt: Date = .distantPast
    private var pausedInPhase: TimeInterval = 0
    private var pausedAt: Date?

    public init(plan: WorkoutPlan) {
        self.plan = plan
    }

    public var currentPhase: Phase? {
        guard status != .idle, status != .finished, status != .aborted, plan.phases.indices.contains(phaseIndex) else { return nil }
        return plan.phases[phaseIndex]
    }

    public var isActive: Bool { status == .running || status == .paused }

    // MARK: Commands

    @discardableResult
    public mutating func start(at now: Date) -> [EngineEvent] {
        guard status == .idle else { return [] }
        startedAt = now
        guard !plan.phases.isEmpty else {
            status = .finished
            endedAt = now
            return [.started(at: now), .finished(at: now)]
        }
        status = .running
        phaseIndex = 0
        phaseStartedAt = now
        pausedInPhase = 0
        return [.started(at: now), .phaseStarted(plan.phases[0], at: now)]
    }

    /// Advances through all phase boundaries that lie in the past.
    @discardableResult
    public mutating func update(at now: Date) -> [EngineEvent] {
        guard status == .running else { return [] }
        var events: [EngineEvent] = []
        while status == .running {
            let phase = plan.phases[phaseIndex]
            let boundary = phaseStartedAt + pausedInPhase + phase.duration
            guard now >= boundary else { break }
            events += endPhase(at: boundary, reason: .completed, nextStart: boundary, nextIndex: phaseIndex + 1)
        }
        return events
    }

    @discardableResult
    public mutating func pause(at now: Date) -> [EngineEvent] {
        var events = update(at: now)
        guard status == .running else { return events }
        status = .paused
        pausedAt = now
        events.append(.paused(at: now))
        return events
    }

    @discardableResult
    public mutating func resume(at now: Date) -> [EngineEvent] {
        guard status == .paused, let pausedAt else { return [] }
        pausedInPhase += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        status = .running
        return [.resumed(at: now)]
    }

    @discardableResult
    public mutating func togglePause(at now: Date) -> [EngineEvent] {
        status == .paused ? resume(at: now) : pause(at: now)
    }

    /// Ends the current phase now and moves to the next one (keeps paused state).
    @discardableResult
    public mutating func skip(at now: Date) -> [EngineEvent] {
        var events = update(at: now)
        guard isActive else { return events }
        let wasPaused = status == .paused
        foldPause(at: now)
        events += endPhase(at: now, reason: .skipped, nextStart: now, nextIndex: phaseIndex + 1)
        if wasPaused, status == .running {
            status = .paused
            pausedAt = now
        }
        return events
    }

    /// Phases the user can finish early with "Hotovo" (activity phases, not rests).
    public static let finishableKinds: Set<PhaseKind> = [.exercise, .warmUp, .stretch]

    public var canFinishEarly: Bool {
        isActive && Self.finishableKinds.contains(plan.phases[phaseIndex].kind)
    }

    /// "Hotovo": the user did the current exercise (or warm-up / stretch) faster than the
    /// interval. Ends it now as `completedEarly` and starts the next phase (keeps paused state).
    @discardableResult
    public mutating func finishEarly(at now: Date) -> [EngineEvent] {
        var events = update(at: now)
        guard canFinishEarly else { return events }
        let wasPaused = status == .paused
        foldPause(at: now)
        events += endPhase(at: now, reason: .completedEarly, nextStart: now, nextIndex: phaseIndex + 1)
        if wasPaused, status == .running {
            status = .paused
            pausedAt = now
        }
        return events
    }

    /// "Zpět o cvik": jumps to the start of the previous exercise phase. If there is no earlier
    /// exercise (e.g. during warm-up or the first exercise), restarts the current phase.
    @discardableResult
    public mutating func back(at now: Date) -> [EngineEvent] {
        var events = update(at: now)
        guard isActive else { return events }
        let wasPaused = status == .paused
        foldPause(at: now)
        let target = plan.phases[..<phaseIndex].last(where: { $0.kind == .exercise })?.index ?? phaseIndex
        events += endPhase(at: now, reason: .back, nextStart: now, nextIndex: target)
        if wasPaused, status == .running {
            status = .paused
            pausedAt = now
        }
        return events
    }

    /// Stops the workout early (session will be marked not completed).
    @discardableResult
    public mutating func abort(at now: Date) -> [EngineEvent] {
        var events = update(at: now)
        guard isActive else { return events }
        foldPause(at: now)
        timings.append(timing(for: plan.phases[phaseIndex], end: now, reason: .aborted))
        events.append(.phaseEnded(timings.last!))
        status = .aborted
        endedAt = now
        events.append(.aborted(at: now))
        return events
    }

    // MARK: Queries

    public func elapsedInPhase(at now: Date) -> TimeInterval {
        guard isActive else { return 0 }
        let reference = pausedAt ?? now
        return max(0, reference.timeIntervalSince(phaseStartedAt) - pausedInPhase)
    }

    public func snapshot(at now: Date) -> EngineSnapshot {
        let phase = currentPhase
        let elapsed = min(elapsedInPhase(at: now), phase?.duration ?? 0)
        let remaining = max(0, (phase?.duration ?? 0) - elapsed)
        let later = isActive ? plan.phases[(phaseIndex + 1)...].reduce(0) { $0 + $1.duration } : 0
        let total: TimeInterval
        if let startedAt { total = (endedAt ?? now).timeIntervalSince(startedAt) } else { total = 0 }
        let current = phase?.exercise
        let next = phase?.upcomingExercise
        return EngineSnapshot(
            status: status,
            phase: phase,
            phaseIndex: phaseIndex,
            phaseCount: plan.phases.count,
            elapsedInPhase: elapsed,
            remainingInPhase: remaining,
            round: phase?.round,
            totalRounds: plan.rounds,
            currentExercise: current,
            nextExercise: next,
            totalElapsed: max(0, total),
            plannedRemaining: isActive ? remaining + later : 0
        )
    }

    /// Exercise checks for every exercise interval that ran to completion (auto-tick, PRD 8a).
    public var completedExerciseChecks: Set<Checklist.ExerciseCheck> {
        Set(timings.compactMap { t in
            guard t.kind == .exercise, t.endReason.isDone, let round = t.round,
                  let idx = plan.phases[t.phaseIndex].exerciseIndex else { return nil }
            return Checklist.ExerciseCheck(round: round, exerciseIndex: idx)
        })
    }

    /// Rounds where every exercise interval was completed.
    public var completedRounds: Set<Int> {
        let checks = completedExerciseChecks
        let n = plan.workout.exercises.count
        guard n > 0 else { return [] }
        return Set((1...plan.rounds).filter { r in (0..<n).allSatisfy { checks.contains(.init(round: r, exerciseIndex: $0)) } })
    }

    public func didComplete(_ kind: PhaseKind) -> Bool {
        timings.contains { $0.kind == kind && $0.endReason.isDone }
    }

    // MARK: Private

    private mutating func foldPause(at now: Date) {
        if let pausedAt {
            pausedInPhase += max(0, now.timeIntervalSince(pausedAt))
            self.pausedAt = nil
            if status == .paused { status = .running }
        }
    }

    private func timing(for phase: Phase, end: Date, reason: PhaseEndReason) -> PhaseTiming {
        PhaseTiming(
            phaseIndex: phase.index, kind: phase.kind, round: phase.round, exerciseID: phase.exercise?.id,
            plannedSeconds: phase.duration, startedAt: phaseStartedAt, endedAt: end,
            pausedSeconds: pausedInPhase, endReason: reason)
    }

    private mutating func endPhase(at end: Date, reason: PhaseEndReason, nextStart: Date, nextIndex: Int) -> [EngineEvent] {
        let phase = plan.phases[phaseIndex]
        let t = timing(for: phase, end: end, reason: reason)
        timings.append(t)
        var events: [EngineEvent] = [.phaseEnded(t)]
        if nextIndex >= plan.phases.count {
            status = .finished
            endedAt = end
            events.append(.finished(at: end))
        } else {
            phaseIndex = nextIndex
            phaseStartedAt = nextStart
            pausedInPhase = 0
            events.append(.phaseStarted(plan.phases[nextIndex], at: nextStart))
        }
        return events
    }
}
