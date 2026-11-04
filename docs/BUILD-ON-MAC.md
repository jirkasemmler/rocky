# Build and run on a Mac

> **Built on a Mac on 2026-11-03** with Xcode 27.2 (iOS / watchOS 27.2 SDKs, deployment
> target 26.0): both schemes build without errors or warnings, the UI tests pass on simulators
> and phone ⇄ watch sync was checked on paired simulators. What still needs a real iPhone and
> Apple Watch is the unticked part of §5.

## 1. Prerequisites

- macOS that supports **Xcode 26 or newer** (iOS 26 / watchOS 26 SDKs or newer; verified with
  Xcode 27.2). Simulators: `xcodebuild -downloadPlatform iOS` and `-downloadPlatform watchOS`.
- Install Xcode from the App Store (or developer.apple.com), open it once, accept the license and
  install the iOS + watchOS platforms when prompted (Xcode → Settings → Components).
- Homebrew, then XcodeGen:

  ```sh
  brew install xcodegen
  ```

- An Apple ID added in Xcode → Settings → Accounts (a free personal team works for running on
  your own devices; HealthKit works with a personal team too).
- iPhone on iOS 26+ and Apple Watch on watchOS 26+ paired with it, both with Developer Mode on
  (Settings → Privacy & Security → Developer Mode).

## 2. Get the code onto the Mac and generate the project

The repository is private on GitHub. Clone it on the Mac (needs access to the private repo,
e.g. `gh auth login` first):

```sh
gh repo clone jirkasemmler/rocky   # or: git clone git@github.com:jirkasemmler/rocky.git
cd rocky
```

Then:

```sh
# optional sanity check of the shared logic (also runs on macOS):
(cd Packages/RockyCore && swift test)
xcodegen generate          # creates Rocky.xcodeproj from project.yml
open Rocky.xcodeproj
```

`Rocky.xcodeproj` is generated and git-ignored; re-run `xcodegen generate` after changing
`project.yml` or adding/removing files.

## 3. Signing and capabilities

For **both** targets (`Rocky` = iPhone, `RockyWatch` = watch) in *Signing & Capabilities*:

1. Tick *Automatically manage signing* and choose your **Team**
   (or set `DEVELOPMENT_TEAM` in `project.yml` and regenerate).
2. If the bundle IDs `cz.semmler.rocky` / `cz.semmler.rocky.watchkitapp` are not
   available to your team, change the prefix in `project.yml` (both IDs **and**
   `WKCompanionAppBundleIdentifier` must match) and regenerate.
3. Check that these capabilities are present (they come from the generated entitlements and
   Info.plist; add them with *+ Capability* if Xcode does not show them):
   - **HealthKit** — watch target (required: writes workouts) and iPhone target (authorization
     prompts may appear on the phone).
   - **Background Modes → Audio, AirPlay, and Picture in Picture** — iPhone target (voice cues
     with locked screen). Watch: *Workout processing* (`WKBackgroundModes`).
   - **App Groups** — `group.cz.semmler.rocky` on the iPhone app, the watch app and the
     complication extension `RockyWatchWidgets` (the complication reads the watch's data file).
   - **Time Sensitive Notifications** — needs a paid developer account; a free Personal Team
     cannot sign it, so the entitlement is commented out in `project.yml` (reminders arrive as
     normal notifications). With a paid team, uncomment it and regenerate.
   - `DEVELOPMENT_TEAM` in `project.yml` is Jiri's Personal Team (`664248ZZ76`); change it for
     another account. Free signing expires after 7 days: rebuild and install again (data stays).
   - The complication extension (`cz.semmler.rocky.watchkitapp.widgets`) needs signing with
     the same team as the watch app.

## 4. Run on device

1. Select scheme **Rocky**, your iPhone as destination, **Run**. The watch app is embedded
   and installs on the paired watch (or select scheme **RockyWatch** and the watch as
   destination to run/debug it directly).
2. On first launch allow notifications (iPhone) and Health access (watch).
3. Czech voice: Settings → Accessibility → Spoken Content → Voices → Czech → download *Zuzana*
   (Enhanced/Premium sounds much better). The app falls back to any installed cs-CZ voice.

## 5. What to verify manually (not testable on Linux)

- [x] Both targets compile (watch app embedded at `Rocky.app/Watch/RockyWatch.app`, complication
      at `RockyWatch.app/PlugIns/RockyWatchWidgets.appex`). *(Mac, 2026-11-03)*
- [x] Simulator: Home, preview, running (warm-up/exercise/rest/pause), checklist, end, summary,
      history, detail, settings, catch-up (short and long debt, postpone menu) — UI tests and
      screenshot tour. *(2026-11-03)*
- [x] Simulator (paired iPhone + Watch): start on phone → watch runs within ~2 s and vice versa;
      skip, pause, end mirror; saving on one device closes the summary on the other. *(2026-11-03)*
- [ ] Device: real sync latency over Bluetooth; starting on the phone with the watch app closed
      (the phone launches it via HealthKit `startWatchApp`).
- [ ] Start a workout on the phone, lock the phone: cues keep coming on time (±200 ms target).
- [ ] Music from another app keeps playing and gets ducked only while a cue is spoken (D-15).
- [ ] Phone call / Siri interrupts → workout pauses.
- [ ] Screen stays on during the running workout (idle timer disabled).
- [ ] Buttons and timer readable from ~2 m.
- [ ] Start on watch → phone mirrors within 2 s, and vice versa; pause/skip/back mirror.
- [ ] Watch: wrist down / display off → haptics still on time; workout appears in Health with
      heart rate, active energy and duration.
- [ ] Watch without phone in range → workout works; session appears on the phone after reconnect.
- [ ] Reminder at the set hour with today's workout name; on every day with debt (also a rest
      day, e.g. Thursday after a skipped Wednesday) +1 h / +2 h, not after 22:30; reminders
      stop after the workout is saved.
- [ ] Skip a training day, do the catch-up the next (rest) day → it shows as caught up.
- [ ] Stretch at the end is always 2:00 (Settings show it read-only).
- [ ] Haptic patterns on the watch are distinguishable (start / last 3 s / rest / round end).
- [ ] Watch summary shows "Uloženo do Zdraví"; the workout is in the Health app.
- [ ] Complication: add "Rocky" to a watch face; it shows today's workout / catch-up / done.
- [ ] Catch-up reminders get through a Focus mode (time-sensitive).
- [ ] Settings → "Přehrát ukázku": Zuzana speaks; rate slider and the address field change the
      voice cues (empty address = "šampione").

## 6. What was verified on Linux (for reference)

- `Packages/RockyCore`: `swift test` — 151 XCTest tests passing (Swift 6.4.2, Linux x86_64).
- `App/Shared` files that only use Foundation/Observation (`TrainingStore`, `WorkoutController`,
  `Formatting`, protocols) type-check against RockyCore on Linux in a scratch package.
- All `App/**/*.swift` files pass `swiftc -parse` (syntax only — **not** a type check against
  UIKit/SwiftUI/HealthKit/WatchConnectivity/AVFoundation).
- `project.yml` — XcodeGen 2.46.0 (built from source on Linux) generated `Rocky.xcodeproj`
  without errors, including the *Embed Dependencies* phase that copies `RockyWatch.app` into
  `$(CONTENTS_FOLDER_PATH)/Watch`, and wrote the committed `Info.plist` / `.entitlements` files.
  Generating a project is not the same as building it.
