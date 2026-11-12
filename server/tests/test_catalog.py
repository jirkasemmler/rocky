"""Catalog: GET with ETag/304, revisions, baseRevision preconditions, rollback (admin API)."""

from __future__ import annotations

import json

from .conftest import SEED


def test_get_catalog_etag_and_304(client, device):
    r = client.get("/api/v1/catalog", headers=device)
    assert r.status_code == 200
    assert r.headers["etag"] == '"rev-1"'
    body = r.json()
    assert body["revision"] == 1
    seed = json.loads(SEED.read_bytes())
    assert [e["id"] for e in body["exercises"]] == [e["id"] for e in seed["exercises"]]
    for value in ('"rev-1"', 'W/"rev-1"', '"rev-0", "rev-1"', "*"):
        r = client.get("/api/v1/catalog", headers={**device, "If-None-Match": value})
        assert r.status_code == 304 and r.content == b"" and r.headers["etag"] == '"rev-1"', value
    assert client.get("/api/v1/catalog", headers={**device, "If-None-Match": '"rev-0"'}).status_code == 200


def test_seed_only_once(settings, ctx):
    assert ctx.catalog.seed_if_empty(settings.seed_path) is False
    assert [r["revision"] for r in ctx.catalog.revisions()] == [1]
    assert ctx.catalog.revisions()[0]["author"] == "seed"


def test_admin_writes_create_revisions_and_check_base(client, admin, device):
    r = admin.api("PUT", "/admin/api/descriptions", json={"warmUpDescription": "Krouž rameny.", "baseRevision": 1})
    assert r.status_code == 200 and r.json() == {"revision": 2}
    # stale base revision -> 409 problem with the current revision
    r = admin.api("PUT", "/admin/api/descriptions", json={"stretchDescription": "Protáhni se.", "baseRevision": 1})
    assert r.status_code == 409 and r.json()["currentRevision"] == 2
    assert r.headers["content-type"] == "application/problem+json"
    assert admin.api("PUT", "/admin/api/descriptions", json={"stretchDescription": "x"}).status_code == 422
    r = client.get("/api/v1/catalog", headers={**device, "If-None-Match": '"rev-1"'})
    assert r.status_code == 200 and r.headers["etag"] == '"rev-2"'
    assert r.json()["warmUpDescription"] == "Krouž rameny."


def new_exercise(**kw):
    ex = {"id": "wall-sit", "name": "Sed u zdi", "techniqueTip": "Záda opři o zeď.",
          "target": {"time": {"minSeconds": 20, "maxSeconds": 40}}, "equipment": "bodyweight", "perSide": False}
    ex.update(kw)
    return ex


def test_exercise_lifecycle(client, admin, device):
    r = admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(), "baseRevision": 1})
    assert r.status_code == 201 and r.json() == {"revision": 2}
    # duplicate id
    r = admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(), "baseRevision": 2})
    assert r.status_code == 409
    # invalid id / data
    r = admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(id="Wall Sit"), "baseRevision": 2})
    assert r.status_code == 422
    r = admin.api("POST", "/admin/api/exercises",
                  json={"exercise": new_exercise(id="x-1", target={"reps": {"min": 5, "max": 1}}), "baseRevision": 2})
    assert r.status_code == 422 and "reps range" in r.json()["detail"]
    # merge patch, null clears optional fields, target replaced wholesale
    r = admin.api("PATCH", "/admin/api/exercises/wall-sit",
                  json={"patch": {"instructions": "1. Opři se.", "target": {"reps": {"min": 5, "max": 8}}},
                        "baseRevision": 2})
    assert r.json() == {"revision": 3}
    ex = next(e for e in client.get("/api/v1/catalog", headers=device).json()["exercises"] if e["id"] == "wall-sit")
    assert ex["instructions"] == "1. Opři se." and ex["target"] == {"reps": {"min": 5, "max": 8}}
    r = admin.api("PATCH", "/admin/api/exercises/wall-sit", json={"patch": {"instructions": None}, "baseRevision": 3})
    assert r.status_code == 200
    ex = next(e for e in client.get("/api/v1/catalog", headers=device).json()["exercises"] if e["id"] == "wall-sit")
    assert "instructions" not in ex
    # immutable id, non-nullable fields
    assert admin.api("PATCH", "/admin/api/exercises/wall-sit",
                     json={"patch": {"id": "other"}, "baseRevision": 4}).status_code == 422
    assert admin.api("PATCH", "/admin/api/exercises/wall-sit",
                     json={"patch": {"name": None}, "baseRevision": 4}).status_code == 422
    assert admin.api("PATCH", "/admin/api/exercises/missing",
                     json={"patch": {"name": "X"}, "baseRevision": 4}).status_code == 404
    # unknown image asset
    assert admin.api("PATCH", "/admin/api/exercises/wall-sit",
                     json={"patch": {"imageAssetID": "a" * 64}, "baseRevision": 4}).status_code == 422


def test_workouts_and_archiving(client, admin, device):
    assert admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(), "baseRevision": 1}).is_success
    r = admin.api("PUT", "/admin/api/workouts/A",
                  json={"exerciseIDs": ["squat", "wall-sit", "push-up"], "name": "Trénink A+", "baseRevision": 2})
    assert r.json() == {"revision": 3}
    cat = client.get("/api/v1/catalog", headers=device).json()
    assert cat["workouts"][0] == {"id": "A", "name": "Trénink A+", "exerciseIDs": ["squat", "wall-sit", "push-up"]}
    # archive fails while used
    r = admin.api("PATCH", "/admin/api/exercises/wall-sit", json={"patch": {"archived": True}, "baseRevision": 3})
    assert r.status_code == 422 and "used in workout A" in r.json()["detail"]
    assert admin.api("PUT", "/admin/api/workouts/A", json={"exerciseIDs": ["squat"], "baseRevision": 3}).is_success
    r = admin.api("PATCH", "/admin/api/exercises/wall-sit", json={"patch": {"archived": True}, "baseRevision": 4})
    assert r.status_code == 200
    # archived exercises stay in the catalog; cannot be put into a workout
    cat = client.get("/api/v1/catalog", headers=device).json()
    assert next(e for e in cat["exercises"] if e["id"] == "wall-sit")["archived"] is True
    r = admin.api("PUT", "/admin/api/workouts/B", json={"exerciseIDs": ["wall-sit"], "baseRevision": 5})
    assert r.status_code == 422 and "archived exercise wall-sit" in r.json()["detail"]
    assert admin.api("PUT", "/admin/api/workouts/D", json={"exerciseIDs": ["squat"], "baseRevision": 5}).status_code == 404


def test_rollback_and_ids_never_reused(client, admin, device, ctx):
    assert admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(), "baseRevision": 1}).is_success
    assert admin.api("PUT", "/admin/api/descriptions", json={"warmUpDescription": "Nová.", "baseRevision": 2}).is_success
    r = admin.api("POST", "/admin/api/rollback", json={"revision": 1, "baseRevision": 2})
    assert r.status_code == 409  # base must be current (3)
    r = admin.api("POST", "/admin/api/rollback", json={"revision": 1, "baseRevision": 3})
    assert r.json() == {"revision": 4}
    cat = client.get("/api/v1/catalog", headers=device).json()
    seed = json.loads(SEED.read_bytes())
    assert cat["revision"] == 4
    assert cat["warmUpDescription"] == seed["warmUpDescription"]
    assert "wall-sit" not in [e["id"] for e in cat["exercises"]]
    revs = ctx.catalog.revisions()
    assert [r["revision"] for r in revs] == [4, 3, 2, 1]
    assert revs[0]["author"] == "admin" and "1" in revs[0]["message"]
    # the id existed once -> cannot be reused
    r = admin.api("POST", "/admin/api/exercises", json={"exercise": new_exercise(), "baseRevision": 4})
    assert r.status_code == 409 and "cannot be reused" in r.json()["detail"]
    assert admin.api("POST", "/admin/api/rollback", json={"revision": 99, "baseRevision": 4}).status_code == 404


def test_revision_metadata_and_audit(admin, ctx, clock):
    clock.advance(minutes=5)
    assert admin.api("PUT", "/admin/api/descriptions",
                     json={"warmUpDescription": "A.", "baseRevision": 1, "message": "kratší"}).is_success
    rev = ctx.catalog.revisions()[0]
    assert rev == {"revision": 2, "author": "admin", "message": "kratší", "createdAt": "2026-11-12T20:05:00Z"}
    with ctx.db.read() as conn:
        row = conn.execute("SELECT * FROM audit WHERE action = 'catalog.descriptions.set'").fetchone()
    assert row["token"] == "jiri" and row["ref"] == "2"
