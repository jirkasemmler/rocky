# Rocky server (docs/SERVER-SPEC.md). Listens on 0.0.0.0:8787 inside the container;
# compose.yaml publishes it on 127.0.0.1 only (Tailscale Serve exposes it to the tailnet).
FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:0.11.14 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    ROCKY_DATA_DIR=/data \
    ROCKY_SEED=/app/seed/catalog.json

WORKDIR /app

# Dependencies first (cached layer), then the app itself.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project

COPY app ./app
COPY seed ./seed
RUN uv sync --locked --no-dev \
    && useradd --system --uid 1000 --home /app rocky \
    && mkdir -p /data && chown rocky /data

USER rocky
VOLUME ["/data"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/healthz', timeout=2)"

CMD ["rocky-server"]
