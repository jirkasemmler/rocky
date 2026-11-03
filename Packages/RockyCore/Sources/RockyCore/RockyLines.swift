import Foundation

/// "Rockyho hlášky": optional funny, motivating Czech lines in the spirit of Rocky Balboa.
///
/// Rules: never insulting, never about body shape or weight; they motivate, they do not shame.
/// Functional cues (exercise name, 3-2-1 countdown, "Pauza.") stay separate, short and come
/// first; flavour lines are extra cues/sentences that can be switched off in Settings.
public enum RockyLineCategory: String, CaseIterable, Sendable, Codable {
    case workoutStart
    case exerciseChange
    case rest
    case lastRound
    case workoutFinished
    case catchUp
    case streak
    case shortened
}

public enum RockyLines {
    /// Placeholder for the user's form of address (vocative), e.g. "Jiří".
    public static let namePlaceholder = "{name}"
    /// Placeholder for "3 týdny" / "5 týdnů" in streak lines.
    public static let weeksPlaceholder = "{weeks}"
    /// Used when no form of address is set in Settings.
    public static let defaultAddress = "šampione"

    public static func templates(_ category: RockyLineCategory) -> [String] {
        switch category {
        case .workoutStart:
            return [
                "Jdeme na to, {name}. Oko tygra!",
                "Gong! Do ringu, {name}.",
                "Rocky běhal po schodech. Ty máš obývák a činky. Stačí to.",
                "Dneska žádné výmluvy. Jen ty, činky a trocha slávy.",
                "Philadelphie se dívá, {name}. Ať je na co koukat.",
            ]
        case .exerciseChange:
            return [
                "Další soupeř do ringu!",
                "Jedeš jak Rocky v mrazírně.",
                "Kolo ještě neskončilo, {name}.",
                "Úder za úderem, opakování za opakováním.",
                "Mickey by byl pyšný.",
            ]
        case .rest:
            return [
                "Dýchej. I Rocky si sedal do rohu.",
                "Krátký oddech. Trenér v rohu kývá: dobrý.",
                "Napij se. I šampioni pijou vodu.",
                "Ramena volně, za chvíli zase do toho.",
            ]
        case .lastRound:
            return [
                "Poslední kolo! Teď se to rozhoduje, {name}.",
                "Poslední kolo. Tohle je ta chvíle na schodech.",
                "Finále! Ještě jedno kolo a jsi nahoře.",
                "Poslední kolo, {name}. Dej do toho srdce.",
            ]
        case .workoutFinished:
            return [
                "Ruce nad hlavu, {name}. Jsi nahoře na schodech!",
                "Adriano, dokázali jsme to! Tedy {name}, dokázal jsi to.",
                "Trénink je doma. Rocky by ti podal rukavici.",
                "Vyhráno na body i na srdce, {name}.",
            ]
        case .catchUp:
            return [
                "Vstávej, Adriano… tedy {name}, dneska to dohnáš.",
                "Včera tě to poslalo k zemi. Dneska se zvedáš.",
                "Nejde o to, jak tvrdě dáváš rány, ale kolik jich vydržíš. Jdeme dohánět.",
                "Zameškaný trénink není knockout. Dneska to srovnáme.",
            ]
        case .streak:
            return [
                "{weeks} v řadě! Oko tygra svítí.",
                "Už {weeks} v kuse, {name}. Tohle je filmová montáž.",
                "{weeks} v řadě. Pás šampiona se blíží.",
                "Série {weeks} v řadě. Rocky by tleskal.",
            ]
        case .shortened:
            return [
                "Dneska zkrácená verze, dvě kola. I krátký sparing se počítá.",
                "Dvě kola místo tří. Hlavně se vrátit do ringu.",
                "Zkrácená verze, {name}. Důležité je, že jsi zase v ringu.",
                "Návrat šampiona začíná dvěma koly.",
            ]
        }
    }

    /// "1 týden", "3 týdny", "5 týdnů".
    public static func weeksPhrase(_ n: Int) -> String {
        switch n {
        case 1: return "1 týden"
        case 2...4: return "\(n) týdny"
        default: return "\(n) týdnů"
        }
    }

    /// Fills placeholders. An empty address falls back to "šampione".
    public static func render(_ template: String, address: String, weeks: Int? = nil) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = template.replacingOccurrences(of: namePlaceholder, with: trimmed.isEmpty ? defaultAddress : trimmed)
        if let weeks {
            text = text.replacingOccurrences(of: weeksPlaceholder, with: weeksPhrase(weeks))
        }
        // Capitalize the first letter (e.g. when a line starts with a placeholder).
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        return text
    }
}

/// Small deterministic PRNG (SplitMix64). Same seed → same sequence on every platform,
/// so flavour selection is reproducible in tests. The app seeds it randomly per workout.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform index in `0..<count` without relying on the stdlib's (unspecified) algorithm.
    public mutating func index(below count: Int) -> Int {
        precondition(count > 0)
        return Int(next() % UInt64(count))
    }
}

/// Picks flavour lines: random via an injected generator, never the same line twice in a row
/// within a category.
public struct RockyPhrasebook: Sendable {
    public var address: String
    private var generator: SeededGenerator
    private var lastIndex: [RockyLineCategory: Int] = [:]

    public init(address: String = "", seed: UInt64) {
        self.address = address
        self.generator = SeededGenerator(seed: seed)
    }

    public mutating func line(_ category: RockyLineCategory, weeks: Int? = nil) -> String {
        let templates = RockyLines.templates(category)
        var i = generator.index(below: templates.count)
        if templates.count > 1, i == lastIndex[category] {
            i = (i + 1) % templates.count
        }
        lastIndex[category] = i
        return RockyLines.render(templates[i], address: address, weeks: weeks)
    }

    /// Stateless deterministic pick, e.g. for a given day (`key` = day number) or streak value.
    public static func line(_ category: RockyLineCategory, key: UInt64, address: String = "", weeks: Int? = nil) -> String {
        var book = RockyPhrasebook(address: address, seed: key)
        return book.line(category, weeks: weeks)
    }
}

extension RockyLines {
    /// Line for the Home screen, stable for the whole day (no flicker on refresh).
    /// Priority: shortened version → catch-up → streak (after today's workout or on a free day).
    public static func homeLine(state: PlannerState, day: Date, address: String) -> String? {
        let key = UInt64(max(0, Int(day.timeIntervalSinceReferenceDate / 86_400)))
        if let due = state.due, state.canStartWorkout {
            if due.isShortened { return RockyPhrasebook.line(.shortened, key: key, address: address) }
            if due.kind == .catchUp { return RockyPhrasebook.line(.catchUp, key: key, address: address) }
        }
        if state.streakWeeks > 0, state.due == nil || state.completedToday {
            return RockyPhrasebook.line(.streak, key: key, address: address, weeks: state.streakWeeks)
        }
        return nil
    }
}
