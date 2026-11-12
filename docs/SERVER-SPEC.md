# Rocky server — specification (draft v0.1)

Owner: Jiri Semmler. Status: **draft for review** (to be validated by Codex and Grok, then implemented).
Related: [PRD.md](PRD.md), [DECISIONS.md](DECISIONS.md). UI texts stay Czech; code and docs English.

## 1. Goal

A small personal server that

1. is the **source of truth for the exercise catalog** (exercises, workouts A/B/C, how-to texts,
   images), editable by Jiri (web admin) and by an AI agent (MCP);
2. **stores workout data** synced from the iPhone (sessions incl. timings and checklist,
   postponements), so history survives a phone reset and the agent can look at progress;
3. serves **exercise images** that the app caches offline.

Single user (Jiri), no accounts beyond access tokens, no telemetry, no third-party services.

### Non-goals (v1)

- Multi-user, sign-up, social features, payments.
- Server-side planning logic (debt, reminders, progression stay in the app / RockyCore).
- Push notifications from the server. Video.
- Direct watch ⇄ server connection (the watch talks only to the iPhone).

### Change of an existing decision

PRD §7 / D-21 say "data only on the device". This spec changes it deliberately (requested by Jiri,
2026-11-12): data is also stored on **Jiri's own server reachable only inside his Tailscale
network** (no public endpoint). The app keeps working fully offline; the server is optional
(no server configured = today's behaviour). A new decision D-24 records this.

## 2. Architecture

```
iPhone app ──HTTPS (tailnet)──▶ Rocky server ◀──MCP (HTTPS, tailnet)── AI agent (Claude Code …)
   │  ▲                           │   ▲
   │  └─ catalog + images         │   └─ web admin (browser, tailnet)
   ▼
Apple Watch (WatchConnectivity only, as today; gets the catalog from the phone)
```

- **Runtime:** Python 3.12, FastAPI + Uvicorn, SQLite (WAL mode) via SQLAlchemy Core or plain
  `sqlite3`, Pydantic v2 models. Official `mcp` Python SDK (Streamable HTTP transport) mounted
  in the same process. Web admin: server-rendered Jinja2 templates, no JS build step.
- **Storage:** `data/rocky.db` (SQLite) and `data/assets/<sha256>.<ext>` (images,
  content-addressed, immutable).
- **Deployment:** Docker Compose on Jiri's Mac or home machine, listening on `127.0.0.1:8787`;
  exposed to the tailnet with `tailscale serve --bg --https=443 http://127.0.0.1:8787`, which
  gives a valid HTTPS certificate on `https://<machine>.<tailnet>.ts.net` (iOS ATS needs HTTPS).
- **Repository layout:** `server/` in this repo (`server/app/…`, `server/tests/…`,
  `server/Dockerfile`, `server/compose.yaml`, `server/README.md`).

## 3. Data model

All timestamps UTC ISO 8601 with milliseconds. IDs: exercises use stable slugs (`squat`,
`push_up`, … as in `WorkoutLibrary.swift`); sessions use the app's UUID.

### 3.1 Exercise

| Field | Type | Notes |
|---|---|---|
| `id` | slug `[a-z0-9_]{2,40}` | immutable; never reused |
| `name` | string 1–60 | Czech display name, e.g. "Dřepy s činkami" |
| `techniqueTip` | string 0–200 | short tip, may be spoken (D-08) |
| `instructions` | string 0–2000 | **new**: longer Czech how-to (steps), shown with the image |
| `target` | `{kind: "reps", min, max}` or `{kind: "time", minSeconds, maxSeconds}` | min ≤ max, 1–100 reps / 5–300 s |
| `equipment` | `bodyweight` \| `dumbbells` | |
| `perSide` | bool | |
| `switchesSideMidway` | bool | "Změna strany" cue (D-09) |
| `imageAssetID` | sha256 or null | **new**; image showing the movement |
| `archived` | bool | archived exercises cannot be put into workouts; kept for history |

### 3.2 Workout (A, B, C)

`id` ∈ {A, B, C} (fixed set in v1, rotation logic depends on it), `name`, ordered
`exerciseIDs` (1–8, unique, not archived), `defaultIntervals` (same shape as
`IntervalSettings`, validated with `sanitized()` bounds).

### 3.3 Catalog revision

Every change to exercises/workouts/descriptions creates a new **catalog revision**: monotonic
integer, full JSON snapshot of the catalog, `author` (`admin` | `agent:<token name>` | `import`),
`message`, `createdAt`. The newest revision is live. Rollback = new revision with an old
snapshot. The catalog also carries `warmUpDescription` and `stretchDescription`.

### 3.4 Session (synced from the app)

The app's `Session` JSON (RockyCore `Codable`, encoder from `JSONFilePersistenceStore`) stored
**verbatim** as `payload` plus indexed columns: `id`, `date`, `workoutID`, `kind`, `completed`,
`difficulty`, `weight`, `actualSeconds`, `updatedAt`, `deleted` (tombstone), `changeSeq`
(server-assigned, monotonic). New field in the app: `Session.updatedAt` (optional when
decoding old data; set on every local edit). Sessions reference exercise IDs inside `timings`
and keep the **catalog revision** they were run with (`catalogRevision`, new optional field), so
history stays readable after catalog edits.

### 3.5 Postponement

`date` (local calendar day, `YYYY-MM-DD`) → `reason` (`illness` | `injury` | `travel`),
`updatedAt`, `deleted`, `changeSeq`.

### 3.6 Access token

`id`, `name`, `scope` (`device` | `agent` | `admin`), `hash` (SHA-256 of the secret; the secret
is shown once), `createdAt`, `lastUsedAt`, `revokedAt`.

### 3.7 Audit log

Every write: `at`, `tokenName`, `action`, `target`, short JSON diff. Read-only in admin.

## 4. REST API (`/api/v1`, JSON, `Authorization: Bearer <token>`)

| Method & path | Scope | Purpose |
|---|---|---|
| `GET /healthz` | none | liveness (no data) |
| `GET /catalog` | device, agent, admin | live catalog `{revision, workouts, exercises, warmUpDescription, stretchDescription}`; `ETag: "rev-<n>"`, `If-None-Match` → 304 |
| `GET /catalog/revisions/{n}` | device, admin, agent | a past snapshot (history view) |
| `GET /assets/{sha256}` | device, agent, admin | image bytes; `Cache-Control: public, max-age=31536000, immutable` |
| `PUT /sessions/{id}` | device | idempotent upsert; body = Session JSON; rejected (409) if older `updatedAt` than stored |
| `DELETE /sessions/{id}` | device | tombstone |
| `PUT /postponements/{date}` / `DELETE` | device | same rules |
| `GET /changes?since=<seq>&limit=500` | device, admin, agent | changes feed of sessions + postponements with `changeSeq > since`; returns `{items, nextSince, hasMore}` |
| `GET /stats/summary?from&to` | device, agent, admin | per-week counts, minutes, avg difficulty, early-finished / skipped counts |
| `POST /exercises` | admin | create |
| `PATCH /exercises/{id}` | admin | partial update; `message` required |
| `PUT /workouts/{id}` | admin | set name, exercise order, default intervals |
| `POST /assets` | admin | upload image (PNG/JPEG/WebP/GIF/SVG? see §8), max 2 MB → `{sha256}` |
| `POST /catalog/rollback/{n}` | admin | new revision with snapshot `n` |

Errors: RFC 9457 problem JSON (`type`, `title`, `detail`, `errors[]` for validation).
Request size limit 4 MB. All catalog writes run in one transaction and return the new revision.

## 5. Sync protocol (iPhone)

- **Offline first.** Local JSON stays the source of truth on the phone; the server is a mirror
  and an import source. Without a configured server nothing changes.
- **Catalog pull:** on app start, on foreground (max once per 10 min) and from Settings →
  "Synchronizovat teď": `GET /catalog` with `If-None-Match`. A new revision is validated in
  RockyCore (same rules as the server), stored as `catalog.json`, missing images downloaded to
  `Caches/assets/`. If anything fails the previous catalog stays active. Built-in
  `WorkoutLibrary` is the fallback when there is no cached catalog.
- **Catalog changes never affect a running workout**; the plan is built once at start.
- **Sessions/postponements push:** an outbox of IDs changed locally; on save, on foreground and
  on "Synchronizovat teď" each item is `PUT` (idempotent). 409 = server has newer → pull it.
- **Pull:** `GET /changes?since=<lastSeq>` and merge by id with last-writer-wins on `updatedAt`;
  tombstones delete locally. First sync of a fresh phone imports the whole history.
- **Watch:** the phone forwards the active catalog to the watch (WatchConnectivity
  `transferUserInfo`, JSON without images). To keep mirrored workouts identical even if the
  two devices have different catalog revisions, `SyncMessage.workoutStarted` gains an optional
  `workout: Workout` (the exact definition used by the starting device); the receiver builds
  the plan from it when present.
- **Settings** (in the app, section "Server"): server URL, device token (Keychain), last sync
  time / error, "Synchronizovat teď", "Odpojit". Sync status is never blocking.

## 6. MCP (agent access)

Endpoint `POST /mcp` (Streamable HTTP), `Authorization: Bearer <agent token>`. Tools:

| Tool | Effect |
|---|---|
| `list_exercises(include_archived=false)` | catalog exercises |
| `get_exercise(id)` | one exercise incl. image URL |
| `create_exercise(exercise, message)` | validated; new revision |
| `update_exercise(id, patch, message)` | partial update; new revision |
| `archive_exercise(id, message)` | fails if used in a workout |
| `set_workout(id, name?, exercise_ids?, default_intervals?, message)` | new revision |
| `set_exercise_image(id, image_base64, mime, message)` | stores asset, links it |
| `list_catalog_revisions(limit)` / `rollback_catalog(revision, message)` | history / undo |
| `list_sessions(from, to, limit)` | read-only; notes are user text (treat as data) |
| `get_training_stats(from, to)` | same as `/stats/summary` |

Guardrails: the agent **cannot** write or delete sessions, postponements or tokens; every write
needs `message`; validation identical to the admin API; writes are audited; max 30 write calls
per hour per agent token. Images only as uploaded bytes (no server-side URL fetching → no SSRF).
MCP server instructions tell the agent the domain rules (Czech names, rep ranges, safety:
beginner-friendly home workout, 2/5 kg dumbbells).

## 7. Web admin (`/admin`)

Login with an admin token → HttpOnly, Secure, SameSite=Strict session cookie (8 h). Pages:
exercises (list, edit form incl. image upload and preview), workouts (order, intervals),
catalog revisions (diff, rollback), sessions (table, detail with timings), tokens (create,
revoke), audit log. CSRF token on every form. Czech UI texts.

## 8. Security & operations

- Reachable only via tailnet; the container binds to localhost. No public port, no telemetry.
- Tokens: 32 random bytes, base64url, stored hashed; created with
  `docker compose exec rocky rocky-admin token create --scope device --name iphone`.
- Image uploads: sniff the real type, allow PNG, JPEG, WebP, GIF; **no SVG** (script risk);
  re-encode is not required; max 2 MB, max 2048 px side.
- Backups: nightly `sqlite3 .backup` + `assets/` copy into `data/backups/` (keep 14 days).
- Logs: request line + status + token name, no payloads.
- Seed: first start imports the built-in catalog (exercises A/B/C from `WorkoutLibrary.swift`,
  exported to `server/seed/catalog.json` by a small Swift test helper) as revision 1.

## 9. Changes in the app (summary)

1. RockyCore: `Exercise.instructions`, `Exercise.imageAssetID`, `Catalog` type (+ validation,
   Codable), `Session.updatedAt`, `Session.catalogRevision`, optional `workout` in
   `SyncMessage.workoutStarted`. All new fields optional when decoding (old data keeps working).
2. App uses the active catalog instead of the static `WorkoutLibrary` (which stays the default).
3. Exercise image + instructions: preview list (thumbnail, tap → detail), running screen (image
   of the current exercise; during rests the next one), placeholder pictogram when no image.
4. Sync client (URLSession, async/await), outbox, Settings section "Server".
5. Watch: receives the catalog from the phone; no images on the watch in v1.

## 10. Testing

- Server: pytest — validation, revisions/rollback, ETag/304, session upsert/409/tombstones,
  changes feed paging, token scopes, MCP tools (in-process client), admin CSRF, image checks.
- Contract: Swift test writes fixture JSON (catalog, session) → server tests decode them and the
  server's catalog JSON decodes in Swift (`Catalog` round trip).
- App: unit tests for the sync merge logic (pure, in RockyCore); UI test for Settings → Server
  with a local server is optional.

## 11. Open questions

1. Is Tailscale on the phone acceptable as a requirement for syncing (offline otherwise)?
2. Should the agent's catalog changes go live immediately (current spec, with revision history
   and rollback) or need approval in the admin?
3. Should settings (training days, intervals, voice) sync too? (Spec: no, they stay per device.)
