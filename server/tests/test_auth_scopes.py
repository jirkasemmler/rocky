"""Exclusive token scopes on every surface (SERVER-SPEC §5)."""

from __future__ import annotations

import pytest

from .conftest import admin_login, bearer, mcp_call

DEVICE_ENDPOINTS = [
    ("GET", "/api/v1/catalog"),
    ("GET", "/api/v1/changes"),
    ("GET", "/api/v1/assets/" + "0" * 64),
    ("PUT", "/api/v1/records/profile/profile"),
    ("DELETE", "/api/v1/records/profile/profile"),
]


def test_healthz_needs_no_token(client):
    assert client.get("/healthz").json() == {"ok": True}


@pytest.mark.parametrize("method, path", DEVICE_ENDPOINTS)
def test_device_endpoints_reject_missing_invalid_and_other_scopes(client, tokens, method, path):
    r = client.request(method, path)
    assert r.status_code == 401 and r.headers["www-authenticate"] == "Bearer"
    assert r.headers["content-type"] == "application/problem+json"
    assert client.request(method, path, headers=bearer("nope")).status_code == 401
    assert client.request(method, path, headers={"Authorization": "Basic abc"}).status_code == 401
    for scope in ("agent", "admin"):
        assert client.request(method, path, headers=bearer(tokens[scope])).status_code == 403, scope


def test_revoked_device_token(client, ctx, tokens):
    assert client.get("/api/v1/catalog", headers=bearer(tokens["device"])).status_code == 200
    ctx.tokens.revoke("iphone")
    assert client.get("/api/v1/catalog", headers=bearer(tokens["device"])).status_code == 401


def test_mcp_only_for_agent_tokens(client, tokens):
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}
    accept = {"Accept": "application/json, text/event-stream"}
    assert client.post("/mcp", json=body, headers=accept).status_code == 401
    assert client.post("/mcp", json=body, headers={**accept, **bearer("bad")}).status_code == 401
    for scope in ("device", "admin"):
        assert client.post("/mcp", json=body, headers={**accept, **bearer(tokens[scope])}).status_code == 403
    r = client.post("/mcp/", json=body, headers={**accept, **bearer(tokens["agent"])})
    assert r.status_code == 200 and r.json()["result"]["tools"]


def test_admin_login_only_for_admin_tokens(client, tokens):
    for scope in ("device", "agent"):
        r = admin_login(client, tokens[scope])
        assert r.status_code == 403 and "rocky_session" not in r.cookies
    assert admin_login(client, "garbage").status_code == 401
    assert admin_login(client, tokens["admin"]).status_code == 303


def test_admin_surfaces_reject_bearer_tokens(client, tokens):
    for scope in ("device", "agent", "admin"):
        h = bearer(tokens[scope])
        assert client.get("/admin/api/catalog", headers=h).status_code == 401
        assert client.get("/admin/exercises", headers=h, follow_redirects=False).status_code == 303


def test_agent_cannot_reach_records_or_rollback(client, tokens):
    h = bearer(tokens["agent"])
    assert client.get("/api/v1/changes", headers=h).status_code == 403
    assert client.put("/api/v1/records/profile/profile", headers=h, content=b"{}").status_code == 403
    r = mcp_call(client, tokens["agent"], "rollback", {"revision": 1})
    assert r["isError"]


def test_tokens_are_stored_hashed(ctx, tokens):
    with ctx.db.read() as conn:
        rows = [tuple(r) for r in conn.execute("SELECT * FROM tokens").fetchall()]
    dump = repr(rows)
    for secret in tokens.values():
        assert secret not in dump
        assert len(secret) >= 43  # 32 random bytes, base64url


def test_token_names_unique_and_scopes_checked(ctx, tokens):
    from app.errors import AppError

    with pytest.raises(AppError):
        ctx.tokens.create("iphone", "device")
    with pytest.raises(AppError):
        ctx.tokens.create("x", "root")
    with pytest.raises(AppError):
        ctx.tokens.create("", "device")


def test_access_log_has_token_name_not_secret(client, tokens, caplog):
    import logging

    with caplog.at_level(logging.INFO, logger="rocky.access"):
        client.get("/api/v1/catalog", headers=bearer(tokens["device"]))
    line = caplog.records[-1].getMessage()
    assert "GET /api/v1/catalog 200 iphone" in line
    assert tokens["device"] not in caplog.text
