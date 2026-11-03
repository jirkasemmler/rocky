import SwiftUI
import TrainingCore

@main
struct TrainingWatchApp: App {
    @State private var store: TrainingStore
    @State private var workout: WorkoutController
    @State private var health: WorkoutSessionService
    private let sync: WatchSyncService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = TrainingStore(persistence: JSONFilePersistenceStore(fileURL: AppConstants.dataFileURL()))
        let sync = WatchSyncService()
        let health = WorkoutSessionService()
        // Voice on the watch is optional (Settings → "Hlas i z hodinek"); haptics are the default.
        let workout = WorkoutController(origin: .watch, speech: SpeechService(audio: nil), haptics: WatchHapticsService(),
                                        audio: nil, sync: sync)
        workout.apply(settings: store.settings, speechEnabled: store.settings.watchSoundEnabled && store.settings.voiceEnabled)

        workout.onStarted = { date in Task { await health.start(at: date) } }
        workout.onPauseChanged = { paused, date in
            if paused { health.pause(at: date) } else { health.resume(at: date) }
        }
        workout.onEnded = { date, _ in
            // Partial workouts are still real exercise; save them to Health too.
            Task { await health.end(at: date, save: true) }
        }

        sync.onMessage = { [weak store, weak workout] message in
            switch message {
            case let .sessionSaved(session, origin) where origin == .phone:
                store?.save(session)
            case let .settingsChanged(settings):
                store?.updateSettings(settings)
                workout?.apply(settings: settings, speechEnabled: settings.watchSoundEnabled && settings.voiceEnabled)
            case .workoutStarted, .command:
                workout?.handleRemote(message)
            }
        }
        sync.activate()

        _store = State(initialValue: store)
        _workout = State(initialValue: workout)
        _health = State(initialValue: health)
        self.sync = sync
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .environment(workout)
                .environment(health)
                .task { await health.requestAuthorization() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    store.refresh()
                    workout.tick()
                }
        }
    }
}

struct WatchRootView: View {
    @Environment(WorkoutController.self) private var workout

    var body: some View {
        switch workout.stage {
        case .idle:
            NavigationStack { WatchStartView() }
        case .running:
            WatchRunningView()
        case let .summary(completed):
            NavigationStack { WatchSummaryView(completed: completed) }
        }
    }
}
