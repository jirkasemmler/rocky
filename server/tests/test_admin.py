"""Web admin: login, cookie session, CSRF, revocation, CSP, pages and forms."""

from __future__ import annotations

import re

from .conftest import admin_login, png_bytes

CSP = "default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'"


def csrf_of(html: str) -> str:
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


def test_pages_redirect_to_login_without_session(client):
    for path in ("/admin", "/admin/exercises", "/admin/workouts", "/admin/descriptions", "/admin/revisions",
                 "/admin/sessions", "/admin/tokens", "/admin/exercises/squat", "/admin/assets/" + "a" * 64):
        r = client.get(path, follow_redirects=False)
        assert r.status_code == 303 and r.headers["location"] == "/admin/login", path


def test_login_sets_strict_cookie(client, tokens):
    r = admin_login(client, tokens["admin"])
    assert r.status_code == 303
    cookie = r.headers["set-cookie"]
    assert "rocky_session=" in cookie and "HttpOnly" in cookie and "Secure" in cookie
    assert "SameSite=strict" in cookie or "SameSite=Strict" in cookie
    assert "Max-Age=28800" in cookie and "Path=/admin" in cookie


def test_login_requires_csrf(client, tokens):
    client.get("/admin/login")
    r = client.post("/admin/login", data={"csrf": "wrong", "token": tokens["admin"]}, follow_redirects=False)
    assert r.status_code == 403
    client.cookies.clear()
    r = client.post("/admin/login", data={"token": tokens["admin"]}, follow_redirects=False)
    assert r.status_code == 403


def test_pages_render_in_czech_with_security_headers(client, admin):
    for path, text in (("/admin/exercises", "Dřepy s činkami"), ("/admin/workouts", "Trénink A"),
                       ("/admin/descriptions", "Rozcvička"), ("/admin/revisions", "seed"),
                       ("/admin/sessions", "Zatím žádné záznamy"), ("/admin/tokens", "jiri"),
                       ("/admin/exercises/plank", "čas (s)"), ("/admin/exercises/new", "Nový cvik")):
        r = client.get(path)
        assert r.status_code == 200 and text in r.text, path
        assert r.headers["content-security-policy"].startswith(CSP)
        assert r.headers["x-frame-options"] == "DENY"
        assert "<script" not in r.text
    css = client.get("/admin/static/admin.css")
    assert css.status_code == 200 and css.headers["content-type"].startswith("text/css")


def test_forms_require_csrf(client, admin):
    r = client.post("/admin/descriptions", data={"warmUp": "x", "stretch": "y", "base_revision": "1"})
    assert r.status_code == 403
    r = client.post("/admin/descriptions", data={"csrf": "bad", "warmUp": "x", "stretch": "y", "base_revision": "1"})
    assert r.status_code == 403
    # admin API needs the header
    assert client.put("/admin/api/descriptions", json={"warmUpDescription": "x", "baseRevision": 1}).status_code == 403
    assert admin.api("PUT", "/admin/api/descriptions", json={"warmUpDescription": "x", "baseRevision": 1}).status_code == 200


def test_edit_exercise_form_with_image(client, admin, ctx):
    page = client.get("/admin/exercises/squat")
    data = {"csrf": csrf_of(page.text), "base_revision": "1", "name": "Dřepy", "techniqueTip": "Paty dolů.",
            "instructions": "1. Stoupni si.\r\n2. Dřepni.", "targetType": "reps", "min": "10", "max": "12",
            "equipment": "dumbbells"}
    r = client.post("/admin/exercises/squat", data=data, files={"image": ("a.png", png_bytes(), "image/png")},
                    follow_redirects=False)
    assert r.status_code == 303, r.text
    rev, body = ctx.catalog.current()
    ex = body.exercise("squat")
    assert rev == 2 and ex.name == "Dřepy" and ex.instructions == "1. Stoupni si.\n2. Dřepni."
    assert ex.imageAssetID and ex.target.reps.min == 10
    # preview served via the cookie-protected admin route
    page = client.get("/admin/exercises/squat")
    assert f'/admin/assets/{ex.imageAssetID}' in page.text
    img = client.get(f"/admin/assets/{ex.imageAssetID}")
    assert img.status_code == 200 and img.headers["content-type"] == "image/png"
    # stale form -> re-rendered with the Czech conflict message, input kept
    r = client.post("/admin/exercises/squat", data={**data, "name": "Jiné jméno"})
    assert r.status_code == 409 and "Katalog se mezitím změnil" in r.text and "Jiné jméno" in r.text
    # remove the image
    data = {**data, "csrf": csrf_of(page.text), "base_revision": "2", "removeImage": "on"}
    assert client.post("/admin/exercises/squat", data=data, follow_redirects=False).status_code == 303
    assert ctx.catalog.current()[1].exercise("squat").imageAssetID is None
    # svg upload rejected
    data["base_revision"] = "3"
    r = client.post("/admin/exercises/squat", data=data, files={"image": ("a.svg", b"<svg/>", "image/svg+xml")})
    assert r.status_code == 422 and "Obrázek nelze použít" in r.text


def test_create_archive_workout_descriptions_rollback_forms(client, admin, ctx):
    csrf = admin.csrf
    r = client.post("/admin/exercises/new", data={
        "csrf": csrf, "base_revision": "1", "id": "wall-sit", "name": "Sed u zdi", "techniqueTip": "",
        "targetType": "time", "min": "20", "max": "40", "equipment": "bodyweight"}, follow_redirects=False)
    assert r.status_code == 303
    r = client.post("/admin/workouts/A", data={"csrf": csrf, "base_revision": "2", "name": "A",
                                               "exerciseIDs": "squat, wall-sit"}, follow_redirects=False)
    assert r.status_code == 303
    assert ctx.catalog.current()[1].workouts[0].exerciseIDs == ["squat", "wall-sit"]
    r = client.post("/admin/exercises/wall-sit/archive", data={"csrf": csrf, "base_revision": "3", "archived": "1"})
    assert r.status_code == 422 and "Nelze uložit" in r.text and "used in workout A" in r.text
    # push-up is no longer in any workout -> can be archived
    r = client.post("/admin/exercises/push-up/archive", data={"csrf": csrf, "base_revision": "3", "archived": "1"},
                    follow_redirects=False)
    assert r.status_code == 303 and ctx.catalog.current()[1].exercise("push-up").archived
    r = client.post("/admin/descriptions", data={"csrf": csrf, "base_revision": "4", "warmUp": "Rozcvička.",
                                                 "stretch": "Protažení."}, follow_redirects=False)
    assert r.status_code == 303
    r = client.post("/admin/revisions/1/rollback", data={"csrf": csrf, "base_revision": "5"}, follow_redirects=False)
    assert r.status_code == 303
    rev, body = ctx.catalog.current()
    assert rev == 6 and body.workouts[0].exerciseIDs == ["squat", "push-up", "bent-over-row", "plank"]


def test_escaping(client, admin, ctx):
    assert admin.api("PATCH", "/admin/api/exercises/squat",
                     json={"patch": {"name": "<script>alert(1)</script>"}, "baseRevision": 1}).status_code == 200
    page = client.get("/admin/exercises").text
    assert "<script>alert(1)</script>" not in page and "&lt;script&gt;" in page


def test_token_management_and_revocation_ends_session(client, admin, ctx):
    r = client.post("/admin/tokens", data={"csrf": admin.csrf, "name": "claude-2", "scope": "agent"})
    assert r.status_code == 200 and "znovu už ho neuvidíš" in r.text
    dup = client.post("/admin/tokens", data={"csrf": admin.csrf, "name": "claude-2", "scope": "agent"})
    assert dup.status_code == 409 and "already exists" in dup.text
    secret = re.search(r'<code class="secret">([^<]+)</code>', r.text).group(1)
    assert ctx.tokens.verify(secret).scope == "agent"
    tid = next(t["id"] for t in ctx.tokens.list() if t["name"] == "claude-2")
    r = client.post(f"/admin/tokens/{tid}/revoke", data={"csrf": admin.csrf}, follow_redirects=False)
    assert r.status_code == 303 and ctx.tokens.verify(secret) is None
    # revoking the admin token (e.g. via the CLI) ends the web session immediately
    assert client.get("/admin/exercises").status_code == 200
    ctx.tokens.revoke("jiri")
    r = client.get("/admin/exercises", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/admin/login"
    assert client.get("/admin/api/catalog").status_code == 401


def test_session_expires_after_8_hours(client, admin, clock):
    clock.advance(hours=7, minutes=59)
    assert client.get("/admin/exercises").status_code == 200
    clock.advance(minutes=2)
    assert client.get("/admin/exercises", follow_redirects=False).status_code == 303


def test_logout(client, admin):
    r = client.post("/admin/logout", data={"csrf": admin.csrf}, follow_redirects=False)
    assert r.status_code == 303
    assert client.get("/admin/api/catalog").status_code == 401


def test_sessions_page_lists_synced_sessions(client, admin, device):
    from .conftest import fixture_bytes

    body = fixture_bytes("session.json")
    client.put("/api/v1/records/session/6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10", content=body,
               headers={**device, "If-None-Match": "*"})
    page = client.get("/admin/sessions").text
    assert "Kolena OK, plank těžký" in page and "18:35" in page
