import Foundation
import RockyCore

enum Format {
    /// "0:40", "12:05"
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "19 min"
    static func minutes(_ seconds: TimeInterval) -> String {
        "\(Int((seconds / 60).rounded())) min"
    }

    /// Czech plural: 1 kolo, 2–4 kola, 5+ kol.
    static func rounds(_ n: Int) -> String {
        switch n {
        case 1: return "1 kolo"
        case 2...4: return "\(n) kola"
        default: return "\(n) kol"
        }
    }

    /// Czech plural: 1 trénink, 2–4 tréninky, 5+ tréninků.
    static func workouts(_ n: Int) -> String {
        switch n {
        case 1: return "1 trénink"
        case 2...4: return "\(n) tréninky"
        default: return "\(n) tréninků"
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.setLocalizedDateFormatFromTemplate("EEEE d. M.")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func phaseTitle(_ snapshot: EngineSnapshot) -> String {
        guard let phase = snapshot.phase else {
            return snapshot.status == .finished ? "Hotovo" : "Připraveno"
        }
        switch phase.kind {
        case .exercise: return phase.exercise?.name ?? "Cvik"
        default: return phase.kind.label
        }
    }

    static func dueTitle(_ due: DueWorkout) -> String {
        let name = LocalizedText.workoutName(due.workoutID)
        switch due.kind {
        case .planned: return name
        case .catchUp: return "Dohon: \(name)"
        case .easyReturn: return "Lehčí návrat: \(name)"
        }
    }
}

extension SessionKind {
    var label: String {
        switch self {
        case .planned: return "Plánovaný"
        case .catchUp: return "Dohnaný"
        case .easyReturn: return "Lehčí návrat"
        case .bonus: return "Bonus"
        }
    }
}

extension TimeOfDay {
    func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    init(date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}
