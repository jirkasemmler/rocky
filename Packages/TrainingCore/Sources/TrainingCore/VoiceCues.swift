import Foundation

/// Haptic patterns shared by iPhone and Watch (PRD 8a: distinct patterns for exercise start,
/// last 3 s countdown, rest and end of round).
public enum HapticPattern: String, Sendable, Codable, CaseIterable {
    case exerciseStart
    case countdownTick
    case restStart
    case roundEnd
    case workoutEnd
}

public enum VoiceCueKind: String, Sendable, Codable, CaseIterable {
    case warmUpStart
    /// Announces the next exercise shortly before it starts.
    case announceNext
    case techniqueTip
    case countdown
    /// "Změna cviku" / start of an exercise.
    case exerciseStart
    case switchSide
    /// "Pauza".
    case restStart
    /// "Konec kola".
    case roundEnd
    case stretchStart
    /// "Konec tréninku".
    case workoutEnd
}

/// A single spoken cue, positioned relative to the start of a phase. Because the position is
/// relative to the phase (not the workout), pause/skip/back keep cues correct.
public struct VoiceCue: Sendable, Equatable, Identifiable {
    /// Stable id: "<phaseIndex>-<kind>-<offset ms>".
    public var id: String
    public var phaseIndex: Int
    /// Seconds after the start of `phaseIndex` when the cue should fire.
    public var offset: TimeInterval
    public var kind: VoiceCueKind
    /// Czech text to speak (cs-CZ).
    public var text: String
    public var haptic: HapticPattern?

    public init(phaseIndex: Int, offset: TimeInterval, kind: VoiceCueKind, text: String, haptic: HapticPattern?) {
        self.phaseIndex = phaseIndex
        self.offset = offset
        self.kind = kind
        self.text = text
        self.haptic = haptic
        self.id = "\(phaseIndex)-\(kind.rawValue)-\(Int((offset * 1000).rounded()))"
    }
}

public struct VoiceCueConfig: Sendable, Equatable {
    /// Seconds of countdown at the end of a phase ("tři, dva, jedna").
    public var countdownSeconds: Int
    /// When the next-exercise announcement starts, in seconds before the exercise begins.
    ///
    /// PRD: "ohlásí cvik 3 s před startem, odpočet 3-2-1". Both cannot be spoken in the same
    /// 3 seconds, so by default the announcement starts 3 s before the countdown (6 s before the
    /// start) and finishes before "tři". See docs/DECISIONS.md (D-07).
    public var announceLeadSeconds: TimeInterval
    public var techniqueTipsEnabled: Bool
    /// Speak tips only in the first round (avoids repeating the same tip 3x).
    public var tipsOnlyFirstRound: Bool
    /// Rough time a tip needs to be spoken; a tip is only scheduled if it fits before the announcement.
    public var tipWindowSeconds: TimeInterval

    public init(countdownSeconds: Int = 3, announceLeadSeconds: TimeInterval = 6, techniqueTipsEnabled: Bool = true,
                tipsOnlyFirstRound: Bool = true, tipWindowSeconds: TimeInterval = 6) {
        self.countdownSeconds = countdownSeconds
        self.announceLeadSeconds = announceLeadSeconds
        self.techniqueTipsEnabled = techniqueTipsEnabled
        self.tipsOnlyFirstRound = tipsOnlyFirstRound
        self.tipWindowSeconds = tipWindowSeconds
    }
}

/// Turns a `WorkoutPlan` into cue data. Pure: no audio. The app feeds cues to its SpeechService
/// and HapticsService.
public struct VoiceCueScheduler: Sendable {
    public let plan: WorkoutPlan
    public let config: VoiceCueConfig
    /// All cues, grouped by phase index, each group sorted by offset.
    public let cuesByPhase: [[VoiceCue]]

    public init(plan: WorkoutPlan, config: VoiceCueConfig = VoiceCueConfig()) {
        self.plan = plan
        self.config = config
        self.cuesByPhase = VoiceCueScheduler.build(plan: plan, config: config)
    }

    public var allCues: [VoiceCue] { cuesByPhase.flatMap { $0 } }

    public func cues(forPhase index: Int) -> [VoiceCue] {
        cuesByPhase.indices.contains(index) ? cuesByPhase[index] : []
    }

    /// Cues of `phaseIndex` whose offset lies in `(fromElapsed, toElapsed]`.
    /// Use `fromElapsed = -1` right after a phase starts to include offset-0 cues.
    public func cues(forPhase index: Int, from fromElapsed: TimeInterval, through toElapsed: TimeInterval) -> [VoiceCue] {
        cues(forPhase: index).filter { $0.offset > fromElapsed && $0.offset <= toElapsed }
    }

    /// Cues with absolute plan offsets (assuming no pause/skip) — useful for previews and tests.
    public func timeline() -> [(time: TimeInterval, cue: VoiceCue)] {
        let offsets = plan.plannedOffsets
        return allCues.map { (offsets[$0.phaseIndex] + $0.offset, $0) }.sorted { $0.time < $1.time }
    }

    // MARK: Text

    static let countdownWords = ["jedna", "dva", "tři", "čtyři", "pět"]

    static func countdownWord(_ n: Int) -> String {
        (1...countdownWords.count).contains(n) ? countdownWords[n - 1] : "\(n)"
    }

    static func secondsPhrase(_ s: Int) -> String {
        if s % 60 == 0 {
            let m = s / 60
            switch m {
            case 1: return "jedna minuta"
            case 2: return "dvě minuty"
            case 3, 4: return "\(m) minuty"
            default: return "\(m) minut"
            }
        }
        switch s {
        case 1: return "jedna sekunda"
        case 2, 3, 4: return "\(s) sekundy"
        default: return "\(s) sekund"
        }
    }

    // MARK: Build

    private static func build(plan: WorkoutPlan, config: VoiceCueConfig) -> [[VoiceCue]] {
        var result: [[VoiceCue]] = Array(repeating: [], count: plan.phases.count)
        let phases = plan.phases

        for phase in phases {
            var cues: [VoiceCue] = []
            let d = phase.duration
            let next = phases.indices.contains(phase.index + 1) ? phases[phase.index + 1] : nil

            // 1) Cue at the start of the phase.
            switch phase.kind {
            case .warmUp:
                cues.append(VoiceCue(phaseIndex: phase.index, offset: 0, kind: .warmUpStart,
                                     text: "Rozcvička, \(secondsPhrase(Int(d))). \(WorkoutLibrary.warmUpDescription)",
                                     haptic: .exerciseStart))
            case .exercise:
                let name = phase.exercise?.name ?? ""
                let isFirst = phase.index == phases.first(where: { $0.kind == .exercise })?.index
                let text = isFirst ? "Začínáme. \(name)." : "Změna cviku. \(name)."
                cues.append(VoiceCue(phaseIndex: phase.index, offset: 0, kind: .exerciseStart, text: text, haptic: .exerciseStart))
            case .rest:
                cues.append(VoiceCue(phaseIndex: phase.index, offset: 0, kind: .restStart, text: "Pauza.", haptic: .restStart))
            case .roundRest:
                let r = phase.round ?? 0
                cues.append(VoiceCue(phaseIndex: phase.index, offset: 0, kind: .roundEnd,
                                     text: "Konec kola \(r). Pauza \(secondsPhrase(Int(d))).", haptic: .roundEnd))
            case .stretch:
                let afterLastRound = phase.index > 0 && phases[phase.index - 1].kind == .exercise
                let prefix = afterLastRound ? "Konec kola \(plan.rounds). " : ""
                cues.append(VoiceCue(phaseIndex: phase.index, offset: 0, kind: .stretchStart,
                                     text: "\(prefix)Teď protažení. \(WorkoutLibrary.stretchDescription)", haptic: .roundEnd))
            }

            // 2) Side switch halfway through one-side-then-other exercises.
            if phase.kind == .exercise, phase.exercise?.switchesSideMidway == true, d >= 10 {
                cues.append(VoiceCue(phaseIndex: phase.index, offset: (d / 2).rounded(.down), kind: .switchSide,
                                     text: "Změna strany.", haptic: .countdownTick))
            }

            // 3) Tip + announcement of the upcoming exercise, placed in the phase before it.
            if let nextPhase = next, nextPhase.kind == .exercise, let upcoming = nextPhase.exercise {
                let announceAt = max(0, d - config.announceLeadSeconds)
                // An exercise shorter than the lead time would collide with its own start cue.
                if announceAt > 0 || phase.kind != .exercise {
                    let label = phase.kind == .exercise ? "Hned potom" : "Další cvik"
                    cues.append(VoiceCue(phaseIndex: phase.index, offset: announceAt, kind: .announceNext,
                                         text: "\(label): \(upcoming.name), \(upcoming.spokenTargetLabel).", haptic: nil))
                }
                let tipAllowedRound = !config.tipsOnlyFirstRound || (nextPhase.round ?? 1) == 1
                if config.techniqueTipsEnabled, tipAllowedRound, phase.kind != .exercise {
                    let tipAt = max(2, announceAt - config.tipWindowSeconds - 2)
                    if tipAt + config.tipWindowSeconds <= announceAt {
                        cues.append(VoiceCue(phaseIndex: phase.index, offset: tipAt, kind: .techniqueTip,
                                             text: "Tip: \(upcoming.techniqueTip)", haptic: nil))
                    }
                }
            }

            // 4) Countdown in the last seconds of every timed phase except the stretch.
            if phase.kind != .stretch, config.countdownSeconds > 0 {
                let n = min(config.countdownSeconds, Int(d.rounded(.down)) - 1)
                if n > 0 {
                    for k in stride(from: n, through: 1, by: -1) {
                        cues.append(VoiceCue(phaseIndex: phase.index, offset: d - TimeInterval(k), kind: .countdown,
                                             text: countdownWord(k), haptic: .countdownTick))
                    }
                }
            }

            // 5) End of the whole workout: spoken at the end of the last phase.
            if phase.index == phases.count - 1 {
                cues.append(VoiceCue(phaseIndex: phase.index, offset: d, kind: .workoutEnd,
                                     text: "Konec tréninku. Skvělá práce!", haptic: .workoutEnd))
            }
            result[phase.index] = cues.sorted { ($0.offset, order($0.kind)) < ($1.offset, order($1.kind)) }
        }
        return result
    }

    private static func order(_ k: VoiceCueKind) -> Int {
        VoiceCueKind.allCases.firstIndex(of: k) ?? 0
    }
}
