import RockyCore
import SwiftUI
import WidgetKit

@main
struct RockyWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @State private var store: TrainingStore
    @State private var workout: WorkoutController
    @State private var health: WorkoutSessionService
    private let sync: WatchSyncService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = TrainingStore(persistence: JSONFilePersistenceStore(fileURL: AppConstants.dataFileURL()),
                                  catalogURL: AppConstants.catalogFileURL())
        let sync = WatchSyncService()
        let health = WorkoutSessionService()
        // Voice on the watch is optional (Settings → "Hlas i z hodinek"); haptics are the default.
        let workout = WorkoutController(origin: .watch, speech: SpeechService(audio: nil), haptics: WatchHapticsService(),
                                        audio: nil, sync: sync)
        workout.apply(settings: store.settings, speechEnabled: store.settings.watchSoundEnabled && store.settings.voiceEnabled)

        workout.onStarted = { date, _ in Task { await health.start(at: date) } }
        workout.onPauseChanged = { paused, date in
            if paused { health.pause(at: date) } else { health.resume(at: date) }
        }
        workout.onEnded = { date, _ in
            // Partial workouts are still real exercise; save them to Health too.
            Task { await health.end(at: date, save: true) }
        }

        workout.catalogProvider = { [weak store] in store?.catalog ?? .builtIn }
        // Complication shows today's workout / debt: refresh it after every local change.
        store.onChange = { _ in WidgetCenter.shared.reloadAllTimelines() }

        WatchAppDelegate.onWorkoutConfiguration = { [weak workout] _ in
            // Launched by the phone: start the HKWorkoutSession now (keeps the app running); the
            // "workoutStarted" message with the plan follows over WatchConnectivity. If it never
            // comes, discard the empty session after 30 s.
            Task { @MainActor in
                await health.start(at: Date())
                try? await Task.sleep(for: .seconds(30))
                // No workout runs → the session is the empty one from the launch (a real workout
                // reuses it, see `start`'s `session == nil` guard).
                if workout?.isRunning != true {
                    await health.end(at: Date(), save: false)
                }
            }
        }

        sync.onMessage = { [weak store, weak workout] message in
            switch message {
            case let .sessionSaved(session, origin) where origin == .phone:
                store?.save(session)
                workout?.otherDeviceSaved(session)
            case .sessionSaved:
                break
            case let .sessionDiscarded(id, origin) where origin == .phone:
                workout?.otherDeviceDiscarded(sessionID: id)
            case .sessionDiscarded:
                break
            case let .catalogChanged(catalog):
                // Applied only if valid and not older than the watch's own (SERVER-SPEC §7).
                store?.applyCatalog(catalog)
            case let .settingsChanged(settings):
                store?.updateSettings(settings)
                workout?.apply(settings: settings, speechEnabled: settings.watchSoundEnabled && settings.voiceEnabled)
            case .workoutStarted, .command, .liveState:
                workout?.handleRemote(message)
            }
        }
        sync.onReachable = { [weak workout] in workout?.broadcastLive() }
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
                .task {
                    guard !AppConstants.isUITesting else { return }
                    await health.requestAuthorization()
                }
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
