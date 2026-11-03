# Decisions and open questions

Owner: Jiri Semmler. Source of requirements: [PRD.md](PRD.md) (v1.1, Czech; untouched copy in
[PRD-original-v1.1.md](PRD-original-v1.1.md)).

Items marked **proposed, awaiting Jiri's confirmation** are defaults chosen to unblock the
implementation. They are all configurable or isolated in one place so they can be changed cheaply.
Items marked **confirmed by Jiri, 2026-11-03** were reviewed and accepted by Jiri.

## A. Open questions from PRD §11

| # | PRD question | Proposed default | Where it lives | Status |
|---|---|---|---|---|
| Q-1 | Latest hour for escalating notifications? | **22:30**. Escalation = reminder at the set hour, +1 h, +2 h, capped at 22:30; if the set hour itself is after 22:30 only that one reminder is sent. Editable in Settings ("Nejpozději"). | `Settings.latestEscalation`, `DebtPlanner.reminderTimes` | **confirmed by Jiri, 2026-11-03** |
| Q-2 | Only a shortened version when debt is older than 2 days? | **Yes.** Debt older than 2 days (travel days are not counted) collapses to a single *shortened* catch-up (2 rounds). No further debt is accumulated until it is paid; the shortened catch-up stays due every day (rest days included) with escalating reminders. Doing the shortened workout clears the whole long debt. | `DebtPlanner.longDebtThresholdDays`, `DebtPlanner.shortenedRounds` | **confirmed by Jiri, 2026-11-03** |
| Q-3 | Male or female voice, speech rate? | **System Czech voice, default female "Zuzana"** (best installed quality: premium > enhanced > default). Voice is selectable among installed cs-CZ voices; speech rate is a slider in Settings (default 0.5 = iOS default rate). | `Settings.voiceIdentifier` (nil = Zuzana), `Settings.speechRate`, `SpeechService.voice(identifier:)` | **confirmed by Jiri, 2026-11-03** |
| Q-4 | Music / metronome for lowering tempo? | **Out of v1.** The app plays alongside the user's own music (mix + ducking). A tempo metronome ("3 s down") can be added later as an optional cue type. | — | **confirmed by Jiri, 2026-11-03** |

## B. Interpretation decisions (PRD ambiguities)

- **D-01 Training days default Mon/Wed/Fri, reminder 19:00.** PRD says "e.g. Mon, Wed, Fri" and
  "evening". Both editable. *(**confirmed by Jiri, 2026-11-03**)*
- **D-02 Stretching is fixed at exactly 2 minutes.** PRD says "short stretch" without a length.
  It is no longer a setting: `IntervalSettings.stretchSeconds` is a 120 s constant and every plan
  (also the shortened 2-round one) ends with it. Settings show it read-only. A `stretchSeconds`
  value saved by an older build (e.g. 0 or 600) is ignored when loading; the constant is still
  written to JSON so an older paired watch/phone build can decode it.
  *(**confirmed by Jiri, 2026-11-03**)*
- **D-03 Escalation: always on debt days; planned days without debt by toggle.** Every day with
  outstanding debt — planned or not, weekend included — gets the reminder at the set hour, +1 h
  and +2 h, never after `latestEscalation` (22:30; +2 h collapses into the cap, a set hour after
  the cap gives a single reminder). The toggle "Stupňovat i v běžné tréninkové dny" (default
  off) only affects planned and easy-return days without debt: off = one reminder at the set
  hour, on = the same escalation. Reminders stop once the day's workout is saved.
  *(**confirmed by Jiri, 2026-11-03**)*
- **D-04 Catch-up on any day; it replaces a planned workout.** A missed slot is due the very next
  day whether or not it is a training day (skip Wednesday → catch up on Thursday). It can be done
  and recorded on any day (rest days and weekends included); any completed workout on a debt day
  pays the oldest debt. On a planned day the catch-up replaces that day's workout, and that day's
  own slot becomes the next debt (PRD: max 1 workout per day — a second workout the same day
  does not count; the week gets denser, rotation A/B/C shifts). Notifications are re-planned for
  today + 7 days after every saved session/postponement and on app start, projecting misses
  (a slot not done by 23:59 already has next-day catch-up reminders scheduled).
  *(**confirmed by Jiri, 2026-11-03**)*
- **D-05 Illness/injury** clears all debt, excuses the day and the next workout is an
  "easy return" (shortened, 2 rounds). **Travel** excuses the day without creating new debt but
  keeps existing debt (it is just not aged during travel days).
- **D-06 Bonus workouts on rest days are allowed** (they advance the A/B/C rotation and are saved
  as kind `bonus`) but do not fill or create slots. Only on rest days **without debt**: with
  debt, Home offers the catch-up instead, and a workout done that day pays the debt even if it
  was saved as bonus (no conflict with D-04).
- **D-07 Announcement timing.** PRD: "announce the exercise 3 s before start and count down 3-2-1".
  Both cannot be spoken in the same 3 s, so the next exercise is announced at **T−6 s** (finishing
  before the countdown) and "tři, dva, jedna" is spoken at T−3/−2/−1. Configurable
  (`VoiceCueConfig.announceLeadSeconds`).
- **D-08 Technique tips only before round-1 exercises.** The tip for the upcoming exercise is
  spoken during the preceding warm-up/rest, only if it fits before the announcement (so it never
  collides with the countdown), and only in round 1 to keep rounds 2–3 quiet. Can be turned off
  in Settings.
- **D-09 Per-side exercises.** Bent-over row, Bulgarian split squat and side plank say
  "Změna strany" halfway through the interval; reverse lunge and dead bug alternate sides within
  the interval (no cue).
- **D-10 Streak** = consecutive Monday-first weeks in which every training slot was done (a
  catch-up within the same week counts). A past week with an excused slot (illness/injury/travel)
  or with fewer slots than usual (plan started mid-week) is *neutral* if all its other slots were
  done: it neither counts nor breaks the streak. Any other unfulfilled week breaks it. The current
  week adds +1 only once it is complete and never breaks the streak while in progress.
- **D-11 Changing training days** applies to the whole history replay (the planner is a
  deterministic replay from `planStart`). Simple and testable; side effect: past weeks may be
  re-evaluated. Acceptable for v1; a dated settings history can be added later.
- **D-12 Timing suggestions.** "Rests consistently longer" = the average actual rest over the last
  3 sessions exceeds the plan by max(5 s, 25 %) → suggest −5 s rest (min 10 s). "Workout longer
  than 30 min" → suggest one fewer round (min 2).
- **D-13 Progression** (PRD appendix): evaluated only after 14 days of history, over the last
  14 days, needs ≥ 3 rated sessions. Avg difficulty ≤ 2 with 2 kg → switch to 5 kg; ≤ 2.5 → add
  reps; ≤ 3.5 → slow the lowering phase (3 s down); otherwise keep.
- **D-14 Timer = timestamps, not counters.** The engine stores phase start + paused time and
  derives everything from `Date`, so a late tick (background, locked screen, watch wrist-down)
  never drifts. Cues that are more than 1.5 s late are dropped instead of spoken late.
- **D-15 Audio session.** During a workout: `.playback` / `.voicePrompt` / `.mixWithOthers`;
  `.duckOthers` is added only while speaking. A silent `AVAudioEngine` loop keeps the app alive in
  the background (Background Modes → Audio). *UNVERIFIED on device*: whether other audio un-ducks
  without deactivating the session. Fallback if it does not: keep `.duckOthers` for the whole
  workout (music slightly quieter throughout), or pre-render cues with
  `AVSpeechSynthesizer.write` and schedule them on the running engine.
- **D-16 Swift language mode.** `RockyCore` uses Swift 6 language mode (strict concurrency,
  verified on Linux). App targets use Swift 5 mode with `SWIFT_STRICT_CONCURRENCY=complete`
  (diagnostics as warnings) so that the first Xcode build is not blocked by SDK-specific
  concurrency errors that could not be checked on Linux. Plan: fix warnings, then switch to 6.
- **D-17 HealthKit writes only from the watch** (HKWorkoutSession + HKLiveWorkoutBuilder, type
  functional strength training). A workout started on the phone is mirrored to the watch if it is
  reachable, so the watch records it. Phone-only workouts are not written to Health in v1.
  Aborted (partial) workouts are still saved to Health.
- **D-18 Sync.** Live commands (start/pause/skip/back/abort) use `WCSession.sendMessage` when the
  other device is reachable and are dropped otherwise; finished sessions and settings use
  `transferUserInfo` (queued, delivered later). Both devices keep their own local JSON; sessions
  are merged by id (same id on both devices for a mirrored workout, so no duplicates).
- **D-19 Notifications.** Local only, scheduled by the iPhone for the next 7 days (max 60 pending)
  and rescheduled after every change and on app foreground. The watch gets them through the
  standard iPhone→Watch notification forwarding (haptic on the wrist). Interruption level
  `.active`; `.timeSensitive` would need an extra entitlement (left for later).
- **D-20 Checklist auto-tick wins.** Exercise/round/warm-up/stretch items tick automatically when
  an interval runs to completion; a manual untick of an auto-ticked item is re-applied on the
  next tick. Manual ticks of skipped items are kept.
- **D-21 Storage.** One JSON file (`training-data.json`, schemaVersion 1) in the App Group
  container (iPhone) / app container (watch). No accounts, no network, no telemetry.
- **D-22 Bundle IDs** `cz.semmler.rocky` and `cz.semmler.rocky.watchkitapp`, App Group
  `group.cz.semmler.rocky`. Change them in `project.yml` if you use a different prefix.
  *(set with the rename to Rocky requested by Jiri, 2026-11-03)*
- **D-23 Name "Rocky" and "Rockyho hlášky".** The app is called Rocky (after Rocky Balboa).
  Optional flavour lines in Czech — funny and motivating, never insulting, never about body
  shape or weight — for: workout start, exercise change, rest, last round, finished workout,
  missed-workout catch-up, streak and the shortened version (`RockyLines.swift`, 4–5 variants
  each). Rules:
  - Functional cues (exercise name, "Pauza.", "Konec kola", 3-2-1) are unchanged, short and
    always spoken first; a flavour line is a separate, interruptible cue (`VoiceCueKind.flavor`).
  - Placement per workout: opening line in the warm-up (catch-up / shortened variant when it
    applies), every 2nd exercise of a round, rests that carry no technique tip, the round rest
    before the last round, and after "Konec tréninku".
  - Catch-up and shortened reminders get a line in front of the body (titles unchanged);
    Home shows a catch-up / shortened / streak line; Summary shows a "finished" line.
  - Selection: SplitMix64 `SeededGenerator` injected into `RockyPhrasebook`, no immediate
    repeats. The app seeds it from the session ID (iPhone and Watch pick the same lines);
    reminders and Home use the day number (stable for the day). Tests assert membership and
    determinism, not exact texts.
  - Settings: toggle "Rockyho hlášky" (default **on**) and "Oslovení (5. pád)"; empty
    address = "šampione". Older settings files decode with the defaults.

## C. Not implemented yet (known gaps vs. PRD)

- Watch **complication** (PRD 8a) — needs a WidgetKit extension target; not created yet.
- "Graph of the week" exists on Home (minutes per day); no per-session timing graph yet.
- iCloud/backup/export — out of scope (PRD: data only on device).
- Localization catalog: UI strings are Czech literals in code (single-language app per PRD).
