from __future__ import annotations

import io
import json
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.config import Settings
from app.main import create_app

SERVER = Path(__file__).resolve().parent.parent
FIXTURES = SERVER / "tests" / "fixtures"
SEED = SERVER / "seed" / "catalog.json"


class Clock:
    def __init__(self) -> None:
        self.now = datetime(2026, 11, 12, 20, 0, 0, tzinfo=UTC)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **kw) -> None:
        self.now += timedelta(**kw)


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def settings(tmp_path: Path, clock: Clock) -> Settings:
    return Settings(data_dir=tmp_path / "data", seed_path=SEED, backups_enabled=False, clock=clock)


@pytest.fixture
def app(settings):
    return create_app(settings)


@pytest.fixture
def ctx(app):
    return app.state.ctx


@pytest.fixture
def client(app):
    with TestClient(app, base_url="https://testserver") as c:
        yield c


@pytest.fixture
def tokens(ctx) -> dict[str, str]:
    return {
        "device": ctx.tokens.create("iphone", "device"),
        "agent": ctx.tokens.create("claude", "agent"),
        "admin": ctx.tokens.create("jiri", "admin"),
    }


def bearer(secret: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}


@pytest.fixture
def device(tokens) -> dict[str, str]:
    return bearer(tokens["device"])


def fixture_bytes(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def png_bytes(w: int = 4, h: int = 4, color=(200, 30, 30)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


class Admin:
    """Logged-in admin browser session."""

    def __init__(self, client: TestClient, csrf: str):
        self.client = client
        self.csrf = csrf

    def api(self, method: str, path: str, **kw):
        headers = {"X-CSRF-Token": self.csrf, **kw.pop("headers", {})}
        return self.client.request(method, path, headers=headers, **kw)


def admin_login(client: TestClient, secret: str):
    page = client.get("/admin/login")
    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    return client.post("/admin/login", data={"csrf": csrf, "token": secret}, follow_redirects=False)


@pytest.fixture
def admin(client, tokens) -> Admin:
    r = admin_login(client, tokens["admin"])
    assert r.status_code == 303, r.text
    csrf = client.get("/admin/api/session").json()["csrfToken"]
    return Admin(client, csrf)


def mcp_call(client: TestClient, secret: str, name: str, arguments: dict | None = None, rpc_id: int = 1):
    r = client.post(
        "/mcp",
        headers={**bearer(secret), "Accept": "application/json, text/event-stream"},
        json={"jsonrpc": "2.0", "id": rpc_id, "method": "tools/call",
              "params": {"name": name, "arguments": arguments or {}}},
    )
    assert r.status_code == 200, r.text
    return r.json()["result"]


def mcp_json(result) -> object:
    assert not result["isError"], result
    if "structuredContent" in result:
        sc = result["structuredContent"]
        return sc.get("result", sc) if set(sc) == {"result"} else sc
    return json.loads(result["content"][0]["text"])
