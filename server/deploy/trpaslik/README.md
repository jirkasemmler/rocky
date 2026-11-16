# Rocky server on trpaslik

Status 2026-11-16: **running, waiting for the Tailscale login of the sidecar.**

## What runs where

| What | Where | Notes |
|---|---|---|
| Container `rocky` | image `rocky-server:0.1.0` (built on trpaslik from `/opt/rocky/src`) | FastAPI + SQLite, ~70 MB RAM |
| Container `rocky-tailscale` | `tailscale/tailscale:stable` | sidecar, own tailnet node `rocky` → `https://rocky.taile09d6f.ts.net` (Serve 443 → 127.0.0.1:8787, `serve.json`) |
| Compose + source | `/opt/rocky/compose.yaml`, `/opt/rocky/serve.json`, `/opt/rocky/src/` | copied by `deploy.sh` |
| Data | `/srv/rocky/data` (UID 1000), `/srv/rocky/tailscale` (node state) | DB, images, nightly backups in `data/backups` |
| Host port | `127.0.0.1:8787` only | for Holister health checks / local CLI; never 0.0.0.0 |

Nothing else on trpaslik was changed: Holister keeps `https://trpaslik.taile09d6f.ts.net/`
(port 3210), Holly and personal-web untouched. Layout follows the conventions from the smarthome
session DAVID (2026-11-15): compose in `/opt/<svc>`, data in `/srv/<svc>`, system Docker via
`sudo`, log rotation, loopback-only host ports.

## Deploy / update

From the Mac (SSH alias `queeg-ts`, passwordless sudo):

```sh
bash server/deploy/trpaslik/deploy.sh
```

## Next steps (to do)

1. **Tailscale login of the sidecar:** get the URL with
   `ssh queeg-ts 'cd /opt/rocky && sudo docker compose logs tailscale | grep -A1 "To authenticate"'`,
   open it and approve device `rocky` (the 2026-11-15 URL may have expired; restart the sidecar
   for a new one: `sudo docker compose restart tailscale`). Optionally tag it / restrict ACLs.
2. Check from the Mac: `curl https://rocky.taile09d6f.ts.net/healthz`.
3. Tokens (`ssh queeg-ts`, then in `/opt/rocky`):
   `sudo docker compose exec rocky rocky-admin token create --scope device --name iphone`,
   `--scope agent --name claude`, `--scope admin --name jiri`.
4. iPhone: Tailscale app on; Rocky → Nastavení → Server: `https://rocky.taile09d6f.ts.net` + device token.
5. Claude Code MCP: `claude mcp add --transport http rocky https://rocky.taile09d6f.ts.net/mcp --header "Authorization: Bearer <agent token>"`.
6. Off-host copy of `/srv/rocky/data/backups` (backups are on the same disk today).
7. Holister: watch `http://127.0.0.1:8787/healthz` and the age of the last backup.
8. Real exercise images (web admin `/admin` or the agent via MCP).

## Remove

`cd /opt/rocky && sudo docker compose down`, delete `/opt/rocky` and `/srv/rocky`, remove the
device `rocky` in the Tailscale admin console.
