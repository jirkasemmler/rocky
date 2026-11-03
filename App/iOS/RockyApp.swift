import SwiftUI
import RockyCore

@main
struct RockyApp: App {
    @State private var store: TrainingStore
    @State private var workout: WorkoutController
    private let sync: WatchSyncService
    private let notifications: NotificationScheduling
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let persistence = JSONFilePersistenceStore(fileURL: AppConstants.dataFileURL())
        if AppConstants.isUITesting {
            try? FileManager.default.removeItem(at: AppConstants.dataFileURL())
            if let days = AppConstants.uiTestingPlanStartDaysAgo {
                let calendar = Calendar.training
                let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date())) ?? Date()
                try? persistence.save(TrainingData(planStart: start))
            }
        }
        let store = TrainingStore(persistence: persistence)
        let sync = WatchSyncService()
        let audio = AudioSessionController()
        let workout = WorkoutController(origin: .phone, speech: SpeechService(audio: audio), haptics: PhoneHapticsService(),
                                        audio: audio, sync: sync)
        workout.apply(settings: store.settings)
        let notifications = NotificationService()
        let launcher = WatchWorkoutLauncher()
        workout.onStarted = { [weak workout] _ in
            // Make sure the watch app runs (HKWorkoutSession + haptics) and gets the start message,
            // even when it was not open. Its WCSession needs a moment after launch, so retry twice;
            // the watch ignores the repeat once it already runs the workout.
            launcher.launch {
                Task { @MainActor in
                    for delay in [1.5, 4.0] {
                        try? await Task.sleep(for: .seconds(delay))
                        workout?.rebroadcastStart()
                    }
                }
            }
        }

        store.onChange = { [weak store] _ in
            guard let store else { return }
            let reminders = store.upcomingReminders()
            Task { await notifications.reschedule(reminders) }
        }
        sync.onMessage = { [weak store, weak workout] message in
            switch message {
            case let .sessionSaved(session, origin) where origin == .watch:
                store?.save(session)
                workout?.otherDeviceSaved(session)
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
                    guard !AppConstants.isUITesting else { return }
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
    @State private var homePath = NavigationPath()

    var body: some View {
        TabView {
            Tab("Dnes", systemImage: "figure.strengthtraining.functional") {
                NavigationStack(path: $homePath) { HomeView() }
            }
            Tab("Historie", systemImage: "chart.bar.xaxis") {
                NavigationStack { HistoryView() }
            }
            Tab("Nastavení", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        }
        .onChange(of: workout.stage) { _, stage in
            // Pop the preview under the running workout so saving ends on Home.
            if stage == .running { homePath = NavigationPath() }
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
