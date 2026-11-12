# Rocky server

Malý osobní server pro aplikaci Rocky: **katalog cviků** (cviky, tréninky A/B/C, návody, obrázky,
rozcvička a protažení), **záloha tréninkových dat** z iPhonu (záznamy, odklady, začátek plánu),
**MCP** pro AI agenta a **webová administrace**. Specifikace: [docs/SERVER-SPEC.md](../docs/SERVER-SPEC.md)
(v0.2), rozhodnutí D-24 v [docs/DECISIONS.md](../docs/DECISIONS.md).

Jeden uživatel, přístup jen tokeny, žádná telemetrie, žádné služby třetích stran. Server je
dostupný jen v tailnetu (Tailscale Serve), na hostiteli poslouchá jen na `127.0.0.1:8787`.

## Spuštění lokálně (uv)

```bash
cd server
uv sync
uv run pytest                     # testy
ROCKY_DATA_DIR=./data ROCKY_COOKIE_SECURE=0 uv run rocky-server   # http://127.0.0.1:8787
```

`ROCKY_COOKIE_SECURE=0` je jen pro lokální vývoj přes čisté `http://` mimo localhost. Data jsou
v `./data` (`rocky.db`, `assets/`, `backups/`). Při prvním startu se katalog naplní ze
`seed/catalog.json` (revize 1).

## Spuštění v Dockeru

```bash
cd server
mkdir -p data                     # na Linuxu: sudo chown 1000 data (kontejner běží jako uid 1000)
docker compose up -d --build
curl http://127.0.0.1:8787/healthz   # {"ok":true}
```

Kontejner poslouchá na `0.0.0.0:8787` uvnitř, compose ho publikuje jen na `127.0.0.1:8787`.

## Zpřístupnění v tailnetu

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8787
```

Server je pak na `https://<stroj>.<tailnet>.ts.net` s platným certifikátem. Tuto adresu zadáš
v aplikaci (Nastavení → Server) i agentovi.

## Tokeny

Tři oddělené rozsahy: `device` (aplikace v iPhonu), `agent` (MCP), `admin` (přihlášení do webu).
Token jednoho rozsahu jinde nefunguje (403). Server ukládá jen SHA-256 otisk; tajemství se ukáže
jen jednou.

```bash
docker compose exec rocky rocky-admin token create --scope admin  --name jiri
docker compose exec rocky rocky-admin token create --scope device --name iphone
docker compose exec rocky rocky-admin token create --scope agent  --name claude
docker compose exec rocky rocky-admin token list
docker compose exec rocky rocky-admin token revoke claude     # ukončí i přihlášení do webu
docker compose exec rocky rocky-admin audit --limit 50
```

Bez Dockeru: `uv run rocky-admin …` se stejnými argumenty (a `ROCKY_DATA_DIR`).

## Webová administrace

`https://<stroj>.<tailnet>.ts.net/admin` → přihlášení admin tokenem. Cviky (včetně archivovaných,
úprava, obrázek, archivace), tréninky, popisy rozcvičky a protažení, revize katalogu (návrat na
starší revizi), odcvičené záznamy (jen čtení), tokeny (vytvoření, zrušení). Sezení platí 8 hodin;
zrušení tokenu ho ukončí okamžitě.

## Claude Code (MCP)

```bash
claude mcp add --transport http rocky https://<stroj>.<tailnet>.ts.net/mcp \
  --header "Authorization: Bearer <agent token>"
```

Nástroje: `get_catalog`, `get_exercise`, `create_exercise`, `update_exercise`, `archive_exercise`,
`unarchive_exercise`, `set_workout`, `set_descriptions`, `set_exercise_image`, `get_exercise_image`,
`list_catalog_revisions`, `list_sessions`. Každý zápis potřebuje `base_revision` a `message`;
nejvýš 30 zápisů za hodinu na token. Agent nevidí synchronizovaná data (kromě souhrnů tréninků přes
`list_sessions`), tokeny ani návrat revizí.

## Zálohy

Každou noc ve 3:00 (místní čas, `ROCKY_BACKUP_HOUR`) online záloha SQLite + `assets/` do
`data/backups/<datum>/`, drží se 14 posledních. Ručně: `docker compose exec rocky rocky-admin backup`.
Obnova: zastav server, nahraď `data/rocky.db` (a smaž `rocky.db-wal`, `rocky.db-shm`) a
`data/assets/` obsahem zálohy, spusť server. Export katalogu:
`docker compose exec rocky rocky-admin export-catalog [--revision N] > catalog.json`.

---

## API reference (for the app and for developers)

All device endpoints need `Authorization: Bearer <device token>`. Errors are RFC 9457
`application/problem+json` (`{type, title, status, detail, …}`). Request bodies ≤ 4 MB (413).
Dates are ISO 8601 without fractional seconds (`2026-11-12T19:00:00Z`).

| Method & path | Result |
|---|---|
| `GET /healthz` | `{"ok":true}`, no auth |
| `GET /api/v1/catalog` | catalog JSON (`revision`, `warmUpDescription`, `stretchDescription`, `exercises`, `workouts`), `ETag: "rev-<n>"`; `If-None-Match` → 304 |
| `GET /api/v1/assets/{sha256}` | image bytes, sniffed `Content-Type`, immutable caching |
| `PUT /api/v1/records/{kind}/{key}` | body = RockyCore JSON payload; 201 (created) / 200 `{version, changeSeq}` |
| `DELETE /api/v1/records/{kind}/{key}` | 200 `{version, changeSeq}` (tombstone) |
| `GET /api/v1/changes?since=<seq>&limit=500` | `{items: [Record], nextSince, hasMore}` |

`kind`/`key`: `session`/uppercase UUID (= payload `id`), `postponement`/`YYYY-MM-DD` (= payload
`day`), `profile`/`profile`. `Record = {kind, key, version, changeSeq, deleted, updatedAt,
payload|null}`; `payload` is the stored JSON object exactly as uploaded.

Upsert preconditions:

| Server state | `If-None-Match: *` | `If-Match: <n>` |
|---|---|---|
| no record | 201, version 1 | 412 (record unknown; re-create with `If-None-Match: *`) |
| live, version v | 409 `{current}` | n = v → 200, v+1; otherwise 409 `{current}` |
| tombstone, version v | 410 | n = v revives (200, `deleted=false`, v+1, new changeSeq); otherwise 410 |

On a tombstone a PUT without any precondition is 410 too; elsewhere neither header → 428; both → 400; `If-Match: *` on PUT → 400. `If-Match` accepts `3` or `"3"`.
DELETE needs `If-Match: <n>` or `*` (428 otherwise): mismatch on a live record → 409 `{current}`;
unknown key → tombstone version 1; existing tombstone → 200 with its unchanged version/changeSeq.
409 and 410 bodies are problem JSON with an extra `current` member (the Record). Tombstones are
kept forever.

Admin JSON API (`/admin/api/…`, admin cookie session, header `X-CSRF-Token` from
`GET /admin/api/session`): `GET catalog`, `GET/POST exercises`, `PATCH exercises/{id}`
(`{patch, baseRevision, message?}`), `PUT workouts/{id}` (`{name?, exerciseIDs?, baseRevision}`),
`PUT descriptions` (`{warmUpDescription?, stretchDescription?, baseRevision}`), `POST assets`
(multipart `file` → `{sha256}`), `POST rollback` (`{revision, baseRevision}`). Wrong
`baseRevision` → 409 with `currentRevision`.

## Code layout

`app/main.py` (app factory, middleware), `api.py` (device REST), `records.py` (sync records),
`catalog.py` (revisions, writes), `models.py` (wire models, validation mirroring
`Catalog.validate()` in RockyCore), `images.py`, `tokens.py`, `mcp_server.py`, `admin.py` +
`templates/` + `static/`, `backup.py`, `cli.py` (`rocky-admin`). Contract fixtures:
`tests/fixtures/` — `session/postponement/profile.json` and `seed/catalog.json` are written by
the Swift `ServerFixtureTests`; `catalog_response/changes_response/conflict_response.json` are
written by `tests/test_contract_fixtures.py` and decoded by Swift
(`swift test --filter ServerFixtureTests` in `Packages/RockyCore`).
