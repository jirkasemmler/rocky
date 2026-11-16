# Rocky — osobní trenér

> „Vstávej, Adriano… tedy Jiří, dneska to dohnáš.“

Rocky is your personal corner-man: a native iOS (SwiftUI) + Apple Watch app for voice-guided home strength training: three dumbbell
workouts A/B/C rotated on your training days, an interval timer with Czech voice cues and wrist
haptics, a checklist, timing stats, progression advice and an enforcing-but-safe catch-up plan
for missed workouts. Offline, no accounts, no telemetry; all data stays on the device.

Rocky talks Czech and, if you let him, cracks jokes: optional **"Rockyho hlášky"** (funny,
motivating, never insulting) at the start, between exercises, in rests, before the last round,
at the finish, on catch-up days and for streaks. Exercise names and the 3-2-1 countdown always
stay short and clear. Toggle in Settings → Rocky.

Repository: <https://github.com/jirkasemmler/rocky> (private).

Author / owner: Jiri Semmler. Requirements: [docs/PRD.md](docs/PRD.md) (PRD v1.1, Czech).
UI and voice are Czech (cs-CZ); code, file names and commits are English.

## Status

First Mac build: 2026-11-03, Xcode 27.2 (iOS / watchOS 27.2 SDKs, deployment target 26.0),
XcodeGen 2.46.0, Swift 6 language mode everywhere.

| Part | State |
|---|---|
| `Packages/RockyCore` (pure Swift, Foundation only) | **Done and tested**: `swift test` → 151 tests, 0 failures (Linux and macOS). |
| `App/Shared`, `App/iOS`, `App/Watch` (SwiftUI) | **Build clean** (0 errors, 0 warnings) for simulator and device. |
| Watch complication (`App/WatchWidgets`, WidgetKit) | Builds and is embedded in the watch app. Not yet placed on a watch face (manual check). |
| UI tests | `RockyUITests` (iPhone, 3 tests) and `RockyWatchUITests` (1 test) pass on iPhone 17 Pro / Apple Watch Series 11 (46 mm) simulators, iOS / watchOS 27.2. |
| Phone ⇄ watch sync | Verified on paired simulators: start, skip, pause, end mirror in both directions within ~2–3 s; saving on one device closes the summary on the other. |
| Rocky server (`server/`, optional) | FastAPI + SQLite + MCP + web admin per [docs/SERVER-SPEC.md](docs/SERVER-SPEC.md): 116 pytest tests; verified end to end with the app in the simulator (connect, catalog + images from the server, workout upload) and with an MCP client (agent sets an image + instructions). Deployed on trpaslik (2026-11-15) as `https://rocky.taile09d6f.ts.net`, waiting for the Tailscale login of its sidecar: [server/deploy/trpaslik/README.md](server/deploy/trpaslik/README.md). See [server/README.md](server/README.md). |
| Device-only behaviour | Voice with a locked phone, ducking, wrist haptics, Apple Health record, time-sensitive notifications: **not verified yet**, see [docs/BUILD-ON-MAC.md](docs/BUILD-ON-MAC.md) §5. |

## Structure

```
rocky/
├── project.yml                     XcodeGen spec: iOS 26 app + watchOS 26 app, local package
├── Packages/RockyCore/             shared logic (Foundation only), unit-tested on Linux
│   ├── Sources/RockyCore/
│   │   ├── Models.swift            Exercise, Workout, Session, Settings, Checklist, ...
│   │   ├── WorkoutLibrary.swift    workouts A/B/C (Czech names + technique tips)
│   │   ├── WorkoutPlan.swift       warm-up → 3 rounds (work/rest/round rest) → 2 min stretch
│   │   ├── WorkoutEngine.swift     timestamp-based state machine (pause/skip/back, no drift)
│   │   ├── VoiceCues.swift         Czech cue texts + timing, haptic patterns
│   │   ├── RockyLines.swift        "Rockyho hlášky" phrasebook + seeded picker
│   │   ├── WorkoutRunner.swift     engine + clock + cues + checklist auto-tick
│   │   ├── TimingStats.swift       planned vs. actual, rest/round suggestions, weekly minutes
│   │   ├── ProgressionAdvisor.swift  2-week progression advice
│   │   ├── DebtPlanner.swift       slots, missed → debt → catch-up, reminders, streak
│   │   ├── Persistence.swift       versioned local JSON store
│   │   └── SyncMessage.swift       phone ⇄ watch messages
│   └── Tests/RockyCoreTests/       151 XCTest cases
├── App/
│   ├── Shared/                     TrainingStore, WorkoutController, SpeechService (cs-CZ),
│   │                               WatchSyncService (WatchConnectivity), protocols
│   ├── iOS/                        RockyApp, Views (Home, Preview, Running, Summary, History,
│   │                               Settings, Checklist), Services (audio session, notifications,
│   │                               haptics, watch-app launcher)
│   ├── Watch/                      RockyWatchApp, app delegate, Views (Start, Running, Summary),
│   │                               Services (HKWorkoutSession, haptics)
│   ├── WatchWidgets/               watch face complication (WidgetKit extension)
│   ├── UITests/, WatchUITests/     XCUITest: main flows (+ opt-in screenshot tour / sync hold)
│   └── Assets.xcassets             placeholder app icon (tools/make-icon.swift)
├── server/                         optional Rocky server (catalog, images, sync, MCP, web admin)
├── tools/                          make-icon.swift, install-iphone.sh (weekly free re-signing)
└── docs/
    ├── PRD.md                      requirements (v1.1)
    ├── PRD-original-v1.1.md        untouched read-only copy of the original PRD
    ├── DECISIONS.md                decisions + PRD questions (defaults confirmed 2026-11-03)
    ├── prototype/prototype.html    static HTML design mock-up (UI reference only)
    └── BUILD-ON-MAC.md             how to generate, sign and run; what is unverified
```

## Run the core tests

Requires Swift 6.x (Linux or macOS):

```sh
cd Packages/RockyCore
swift test
```

## Run the app tests

```sh
xcodegen generate
xcodebuild -project Rocky.xcodeproj -scheme Rocky      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Rocky.xcodeproj -scheme RockyWatch -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' test
```

The app launched with `-uiTesting` uses a fresh temporary data file and skips the permission
prompts; `-uiTestingPlanStartDaysAgo N` starts the plan N days ago (catch-up states).
`TEST_RUNNER_ROCKY_SCREENSHOT_DIR=<dir>` enables `ScreenshotTour`, which saves a screenshot of
every iPhone screen.

## Key design points

- **Timer accuracy**: the engine derives everything from timestamps (phase start + paused time),
  so late ticks in the background never accumulate drift; stale cues (>1.5 s late) are dropped.
- **Voice**: `AVSpeechSynthesizer` with a Czech system voice (default Zuzana), background audio
  session mixing with the user's music and ducking it while speaking.
- **Watch**: `HKWorkoutSession` (functional strength training) keeps the timer running with the
  display off and writes the workout to Health; distinct haptic patterns per event. A workout
  started on the phone launches the watch app (`startWatchApp`) so it is recorded there too.
  Complication on the watch face: today's workout, catch-up, done / rest day.
- **Catch-up debt**: deterministic day-by-day replay of the plan; missed slot → catch-up the next
  day, even a rest day (on a training day it replaces that day's workout); every day with debt gets
  escalating reminders (set hour, +1 h, +2 h, max 22:30), shortened 2-round version for
  debt older than 2 days, illness/injury clears debt with an easy return.

Open questions and all interpretation choices: [docs/DECISIONS.md](docs/DECISIONS.md).
