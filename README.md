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

| Part | State |
|---|---|
| `Packages/RockyCore` (pure Swift, Foundation only) | **Done and tested**: `swift test` → 132 tests, 0 failures (Swift 6.4.2, Linux x86_64, Swift 6 language mode). |
| `App/Shared` (store, workout controller, services) | Written. Foundation/Observation parts **type-check on Linux**; files using Apple frameworks only syntax-checked. |
| `App/iOS`, `App/Watch` (SwiftUI) | Written, **UNVERIFIED** — never compiled against the iOS/watchOS SDK (no Xcode on Linux). |
| `project.yml` (XcodeGen) | Generates an Xcode project without errors (XcodeGen 2.46.0 on Linux). Not built. |
| Watch complication | Not implemented yet (needs a WidgetKit extension). |

Next step: build on a Mac with Xcode 26 → [docs/BUILD-ON-MAC.md](docs/BUILD-ON-MAC.md).

## Structure

```
rocky/
├── project.yml                     XcodeGen spec: iOS 26 app + watchOS 26 app, local package
├── Packages/RockyCore/             shared logic (Foundation only), unit-tested on Linux
│   ├── Sources/RockyCore/
│   │   ├── Models.swift            Exercise, Workout, Session, Settings, Checklist, ...
│   │   ├── WorkoutLibrary.swift    workouts A/B/C (Czech names + technique tips)
│   │   ├── WorkoutPlan.swift       warm-up → 3 rounds (work/rest/round rest) → stretch
│   │   ├── WorkoutEngine.swift     timestamp-based state machine (pause/skip/back, no drift)
│   │   ├── VoiceCues.swift         Czech cue texts + timing, haptic patterns
│   │   ├── RockyLines.swift        "Rockyho hlášky" phrasebook + seeded picker
│   │   ├── WorkoutRunner.swift     engine + clock + cues + checklist auto-tick
│   │   ├── TimingStats.swift       planned vs. actual, rest/round suggestions, weekly minutes
│   │   ├── ProgressionAdvisor.swift  2-week progression advice
│   │   ├── DebtPlanner.swift       slots, missed → debt → catch-up, reminders, streak
│   │   ├── Persistence.swift       versioned local JSON store
│   │   └── SyncMessage.swift       phone ⇄ watch messages
│   └── Tests/RockyCoreTests/       132 XCTest cases
├── App/
│   ├── Shared/                     TrainingStore, WorkoutController, SpeechService (cs-CZ),
│   │                               WatchSyncService (WatchConnectivity), protocols
│   ├── iOS/                        RockyApp, Views (Home, Preview, Running, Summary, History,
│   │                               Settings, Checklist), Services (audio session, notifications, haptics)
│   └── Watch/                      RockyWatchApp, Views (Start, Running, Summary),
│                                   Services (HKWorkoutSession, haptics)
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

## Key design points

- **Timer accuracy**: the engine derives everything from timestamps (phase start + paused time),
  so late ticks in the background never accumulate drift; stale cues (>1.5 s late) are dropped.
- **Voice**: `AVSpeechSynthesizer` with a Czech system voice (default Zuzana), background audio
  session mixing with the user's music and ducking it while speaking.
- **Watch**: `HKWorkoutSession` (functional strength training) keeps the timer running with the
  display off and writes the workout to Health; distinct haptic patterns per event.
- **Catch-up debt**: deterministic day-by-day replay of the plan; missed slot → catch-up next day
  (replaces that day's workout), escalating reminders until 22:30, shortened 2-round version for
  debt older than 2 days, illness/injury clears debt with an easy return.

Open questions and all interpretation choices: [docs/DECISIONS.md](docs/DECISIONS.md).
