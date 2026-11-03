import RockyCore
import SwiftUI
import WidgetKit

/// Watch face complication (PRD 8a): today's workout letter, catch-up debt or "done".
/// Reads the watch app's local JSON from the shared App Group container and runs the same
/// `DebtPlanner` as the app, so it shows exactly what the watch Start screen shows.
struct RockyEntry: TimelineEntry {
    enum Status: Equatable {
        case due(title: String, letter: String, catchUp: Bool, shortened: Bool)
        case done(next: String)
        case rest(next: String)
        case postponed
    }

    let date: Date
    let status: Status
    let debtCount: Int
    let streakWeeks: Int

    static let placeholder = RockyEntry(date: Date(), status: .due(title: "Trénink A", letter: "A", catchUp: false,
                                                                     shortened: false),
                                        debtCount: 0, streakWeeks: 2)
}

struct RockyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RockyEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RockyEntry) -> Void) {
        completion(context.isPreview ? .placeholder : Self.entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RockyEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.training
        // The app reloads timelines after every change; besides that refresh at midnight (new day,
        // possibly new debt) and at least hourly.
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let next = min(midnight, now.addingTimeInterval(3600))
        completion(Timeline(entries: [Self.entry(at: now), Self.entry(at: midnight)].filter { $0.date <= midnight },
                            policy: .after(next)))
    }

    static func entry(at date: Date) -> RockyEntry {
        let calendar = Calendar.training
        let store = JSONFilePersistenceStore(fileURL: AppConstants.dataFileURL())
        let data = (try? store.load()) ?? TrainingData(planStart: calendar.startOfDay(for: date))
        let state = DebtPlanner(settings: data.settings, calendar: calendar).state(now: date, history: data.history)
        let next = LocalizedText.workoutName(state.nextWorkoutID)
        let status: RockyEntry.Status
        if let due = state.due, state.canStartWorkout {
            status = .due(title: Format.dueTitle(due), letter: due.workoutID.rawValue, catchUp: due.kind == .catchUp,
                          shortened: due.isShortened)
        } else if state.completedToday {
            status = .done(next: next)
        } else if state.postponedToday != nil {
            status = .postponed
        } else {
            status = .rest(next: next)
        }
        return RockyEntry(date: date, status: status, debtCount: state.debt.count, streakWeeks: state.streakWeeks)
    }
}

struct RockyComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RockyEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: Text(inlineText)
        default: rectangular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            switch entry.status {
            case let .due(_, letter, catchUp, _):
                VStack(spacing: -2) {
                    Text(letter).font(.system(size: 22, weight: .heavy, design: .rounded))
                    if catchUp { Image(systemName: "exclamationmark").font(.caption2.bold()) }
                }
            case .done:
                Image(systemName: "checkmark").font(.title2.bold())
            case .rest:
                Image(systemName: "leaf.fill").font(.title3)
            case .postponed:
                Image(systemName: "moon.zzz.fill").font(.title3)
            }
        }
        .widgetAccentable()
    }

    private var corner: some View {
        Image(systemName: symbol)
            .font(.title3)
            .widgetLabel { Text(inlineText) }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Rocky", systemImage: "figure.strengthtraining.functional")
                .font(.headline)
                .widgetAccentable()
            Text(primaryText).font(.body.bold()).lineLimit(1)
            Text(secondaryText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch entry.status {
        case let .due(_, _, catchUp, _): return catchUp ? "exclamationmark.triangle.fill" : "figure.strengthtraining.functional"
        case .done: return "checkmark.seal.fill"
        case .rest: return "leaf.fill"
        case .postponed: return "moon.zzz.fill"
        }
    }

    private var primaryText: String {
        switch entry.status {
        case let .due(title, _, _, _): return title
        case .done: return "Dnes hotovo"
        case .rest: return "Dnes volno"
        case .postponed: return "Odloženo"
        }
    }

    private var secondaryText: String {
        switch entry.status {
        case let .due(_, _, _, shortened):
            if entry.debtCount > 0 { return "Dlužíš \(Format.workouts(entry.debtCount))" + (shortened ? " · 2 kola" : "") }
            return shortened ? "Zkrácená verze · 2 kola" : "Dnešní trénink"
        case let .done(next), let .rest(next):
            return entry.streakWeeks > 0 ? "Další: \(next) · 🔥 \(entry.streakWeeks)" : "Další: \(next)"
        case .postponed:
            return "Odpočívej"
        }
    }

    private var inlineText: String {
        switch entry.status {
        case let .due(title, _, _, _): return title
        case .done: return "Rocky: hotovo"
        case let .rest(next): return "Rocky: volno, pak \(next)"
        case .postponed: return "Rocky: odloženo"
        }
    }
}

struct RockyComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RockyComplication", provider: RockyTimelineProvider()) { entry in
            RockyComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Rocky")
        .description("Dnešní trénink, dohánění a série.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct RockyWidgets: WidgetBundle {
    var body: some Widget { RockyComplication() }
}
