#!/bin/bash
# Deploys / updates the Rocky server on trpaslik (SSH alias queeg-ts, passwordless sudo).
# Copies server/ to /opt/rocky/src, installs compose.yaml + serve.json, builds and (re)starts.
# Data stays in /srv/rocky (data/ owned by UID 1000 = rocky user in the image).
set -euo pipefail
HOST=${HOST:-queeg-ts}
cd "$(dirname "$0")/../.."   # server/

ssh "$HOST" 'sudo mkdir -p /opt/rocky/src /srv/rocky/data /srv/rocky/tailscale \
  && sudo chown -R "$(id -u):$(id -g)" /opt/rocky \
  && sudo chown -R 1000:1000 /srv/rocky/data \
  && sudo chmod 750 /srv/rocky/data'

rsync -a --delete \
  --exclude .venv --exclude data --exclude __pycache__ --exclude .pytest_cache --exclude deploy \
  ./ "$HOST":/opt/rocky/src/
rsync -a deploy/trpaslik/compose.yaml deploy/trpaslik/serve.json "$HOST":/opt/rocky/

ssh "$HOST" 'cd /opt/rocky && sudo docker compose build rocky && sudo docker compose up -d && sleep 5 \
  && sudo docker compose ps && curl -sf http://127.0.0.1:8787/healthz && echo'
