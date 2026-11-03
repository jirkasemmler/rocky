import SwiftUI
import TrainingCore

@main
struct TrainingApp: App {
    @State private var store: TrainingStore
    @State private var workout: WorkoutController
    private let sync: WatchSyncService
    private let notifications: NotificationScheduling
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = TrainingStore(persistence: JSONFilePersistenceStore(fileURL: AppConstants.dataFileURL()))
        let sync = WatchSyncService()
        let audio = AudioSessionController()
        let workout = WorkoutController(origin: .phone, speech: SpeechService(audio: audio), haptics: PhoneHapticsService(),
                                        audio: audio, sync: sync)
        workout.apply(settings: store.settings)
        let notifications = NotificationService()

        store.onChange = { [weak store] _ in
            guard let store else { return }
            let reminders = store.upcomingReminders()
            Task { await notifications.reschedule(reminders) }
        }
        sync.onMessage = { [weak store, weak workout] message in
            switch message {
            case let .sessionSaved(session, origin) where origin == .watch:
                store?.save(session)
            case .workoutStarted, .command:
                workout?.handleRemote(message)
            default:
                break
            }
        }
        sync.activate()

        _store = State(initialValue: store)
        _workout = State(initialValue: workout)
        self.sync = sync
        self.notifications = notifications
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(workout)
                .tint(.green)
                .preferredColorScheme(.dark)
                .task {
                    _ = await notifications.requestAuthorization()
                    await notifications.reschedule(store.upcomingReminders())
                    sync.send(.settingsChanged(store.settings))
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    store.refresh()
                    workout.tick()
                    let reminders = store.upcomingReminders()
                    Task { await notifications.reschedule(reminders) }
                }
                .onChange(of: store.settings) { _, settings in
                    workout.apply(settings: settings)
                    sync.send(.settingsChanged(settings))
                }
        }
    }
}

struct RootView: View {
    @Environment(WorkoutController.self) private var workout

    var body: some View {
        TabView {
            Tab("Dnes", systemImage: "figure.strengthtraining.functional") {
                NavigationStack { HomeView() }
            }
            Tab("Historie", systemImage: "chart.bar.xaxis") {
                NavigationStack { HistoryView() }
            }
            Tab("Nastavení", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { workout.stage != .idle },
            set: { if !$0 { workout.reset() } }
        )) {
            WorkoutFlowView()
        }
    }
}

struct WorkoutFlowView: View {
    @Environment(WorkoutController.self) private var workout

    var body: some View {
        switch workout.stage {
        case .running:
            RunningWorkoutView()
        case let .summary(completed):
            NavigationStack { SummaryView(completed: completed) }
        case .idle:
            EmptyView()
        }
    }
}
