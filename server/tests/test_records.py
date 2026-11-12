"""Records API: upsert / If-Match / If-None-Match / 409 / 410 / tombstones / changes feed."""

from __future__ import annotations

import json

import pytest

from .conftest import fixture_bytes

SESSION_ID = "6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10"
S_URL = f"/api/v1/records/session/{SESSION_ID}"
P_URL = "/api/v1/records/postponement/2026-11-13"
PROFILE_URL = "/api/v1/records/profile/profile"


def put(client, device, url, body: bytes, **headers):
    return client.put(url, content=body, headers={**device, "Content-Type": "application/json", **headers})


def create(client, device, url, body):
    r = put(client, device, url, body, **{"If-None-Match": "*"})
    assert r.status_code == 201, r.text
    return r.json()


def session_with(**changes) -> bytes:
    data = json.loads(fixture_bytes("session.json"))
    data.update(changes)
    return json.dumps(data, ensure_ascii=False).encode()


def test_create_session_stores_exact_bytes(client, device, ctx):
    body = fixture_bytes("session.json")
    assert create(client, device, S_URL, body) == {"version": 1, "changeSeq": 1}
    with ctx.db.read() as conn:
        stored = conn.execute("SELECT payload FROM records WHERE key = ?", (SESSION_ID,)).fetchone()[0]
    assert stored == body  # never re-serialised
    feed = client.get("/api/v1/changes", headers=device).json()
    item = feed["items"][0]
    assert item["payload"] == json.loads(body)  # embedded object, not a string
    assert item["kind"] == "session" and item["key"] == SESSION_ID and item["deleted"] is False
    assert item["updatedAt"] == "2026-11-12T20:00:00Z"


def test_update_requires_matching_version(client, device):
    create(client, device, S_URL, fixture_bytes("session.json"))
    r = put(client, device, S_URL, session_with(note="v2"), **{"If-Match": "1"})
    assert r.status_code == 200 and r.json() == {"version": 2, "changeSeq": 2}
    # stale version -> 409 with the current record
    r = put(client, device, S_URL, session_with(note="stale"), **{"If-Match": "1"})
    assert r.status_code == 409
    current = r.json()["current"]
    assert current["version"] == 2 and current["payload"]["note"] == "v2" and current["deleted"] is False
    # create on an existing record -> 409 too
    r = put(client, device, S_URL, session_with(note="again"), **{"If-None-Match": "*"})
    assert r.status_code == 409 and r.json()["current"]["version"] == 2
    # quoted ETag-style versions are accepted
    r = put(client, device, S_URL, session_with(note="v3"), **{"If-Match": '"2"'})
    assert r.status_code == 200 and r.json()["version"] == 3


def test_preconditions(client, device):
    body = fixture_bytes("session.json")
    assert put(client, device, S_URL, body).status_code == 428
    r = put(client, device, S_URL, body, **{"If-Match": "1", "If-None-Match": "*"})
    assert r.status_code == 400
    assert put(client, device, S_URL, body, **{"If-Match": "*"}).status_code == 400
    # If-Match on a record the server does not have
    r = put(client, device, S_URL, body, **{"If-Match": "3"})
    assert r.status_code == 412
    assert r.headers["content-type"] == "application/problem+json"


@pytest.mark.parametrize(
    "url, body, status",
    [
        (S_URL.lower(), fixture_bytes("session.json"), 400),  # lowercase UUID key
        ("/api/v1/records/session/11111111-1111-1111-1111-111111111111", fixture_bytes("session.json"), 400),
        ("/api/v1/records/postponement/2026-11-14", fixture_bytes("postponement.json"), 400),
        ("/api/v1/records/postponement/2026-13-45", fixture_bytes("postponement.json"), 400),
        ("/api/v1/records/profile/other", fixture_bytes("profile.json"), 400),
        ("/api/v1/records/sessions/x", b"{}", 404),
        (S_URL, b"not json", 400),
        (S_URL, b"[]", 400),
        (S_URL, json.dumps({"id": SESSION_ID}).encode(), 422),
        (S_URL, session_with(date="2026-11-12T18:00:00.123Z"), 422),  # Swift cannot decode fractions
        (S_URL, session_with(difficulty=9), 422),
        (P_URL, json.dumps({"date": "2026-11-13T07:00:00Z", "reason": "bored", "day": "2026-11-13"}).encode(), 422),
    ],
)
def test_key_and_payload_validation(client, device, url, body, status):
    r = put(client, device, url, body, **{"If-None-Match": "*"})
    assert r.status_code == status, r.text
    assert r.headers["content-type"] == "application/problem+json"


def test_unknown_payload_fields_are_kept(client, device):
    body = session_with(futureField={"x": 1})
    create(client, device, S_URL, body)
    item = client.get("/api/v1/changes", headers=device).json()["items"][0]
    assert item["payload"]["futureField"] == {"x": 1}


def test_delete_creates_tombstone_and_410(client, device):
    create(client, device, S_URL, fixture_bytes("session.json"))
    assert client.delete(S_URL, headers=device).status_code == 428
    r = client.delete(S_URL, headers={**device, "If-Match": "7"})
    assert r.status_code == 409 and r.json()["current"]["version"] == 1
    r = client.delete(S_URL, headers={**device, "If-Match": "1"})
    assert r.status_code == 200 and r.json() == {"version": 2, "changeSeq": 2}
    # idempotent on the tombstone
    r = client.delete(S_URL, headers={**device, "If-Match": "*"})
    assert r.status_code == 200 and r.json() == {"version": 2, "changeSeq": 2}
    # only If-Match: <tombstone version> revives; anything else is 410
    for headers in ({"If-None-Match": "*"}, {"If-Match": "1"}, {"If-Match": "3"}):
        r = put(client, device, S_URL, fixture_bytes("session.json"), **headers)
        assert r.status_code == 410, headers
        assert r.json()["current"]["deleted"] is True
    feed = client.get("/api/v1/changes", headers=device).json()
    assert feed["items"] == [{"kind": "session", "key": SESSION_ID, "version": 2, "changeSeq": 2, "deleted": True,
                              "updatedAt": "2026-11-12T20:00:00Z", "payload": None}]


def test_delete_unknown_key_creates_tombstone(client, device):
    r = client.delete(P_URL, headers={**device, "If-Match": "*"})
    assert r.status_code == 200 and r.json() == {"version": 1, "changeSeq": 1}
    r = put(client, device, P_URL, fixture_bytes("postponement.json"), **{"If-None-Match": "*"})
    assert r.status_code == 410


def test_postponement_tombstone_can_be_revived_with_its_version(client, device):
    create(client, device, P_URL, fixture_bytes("postponement.json"))
    assert client.delete(P_URL, headers={**device, "If-Match": "1"}).json()["version"] == 2
    assert put(client, device, P_URL, fixture_bytes("postponement.json"), **{"If-Match": "1"}).status_code == 410
    r = put(client, device, P_URL, fixture_bytes("postponement.json"), **{"If-Match": "2"})
    assert r.status_code == 200 and r.json() == {"version": 3, "changeSeq": 3}
    item = client.get("/api/v1/changes?since=2", headers=device).json()["items"][0]
    assert item["deleted"] is False and item["payload"]["day"] == "2026-11-13"


@pytest.mark.parametrize(
    "url, name",
    [(S_URL, "session.json"), (P_URL, "postponement.json"), (PROFILE_URL, "profile.json")],
)
def test_tombstone_revival_rule_applies_to_every_kind(client, device, ctx, url, name):
    create(client, device, url, fixture_bytes(name))
    assert client.delete(url, headers={**device, "If-Match": "1"}).json() == {"version": 2, "changeSeq": 2}
    # mismatch, create-precondition and a missing precondition never touch the tombstone
    assert put(client, device, url, fixture_bytes(name), **{"If-Match": "1"}).status_code == 410
    assert put(client, device, url, fixture_bytes(name), **{"If-Match": "5"}).status_code == 410
    assert put(client, device, url, fixture_bytes(name), **{"If-None-Match": "*"}).status_code == 410
    assert put(client, device, url, fixture_bytes(name)).status_code == 410
    feed = client.get("/api/v1/changes", headers=device).json()
    assert [(i["version"], i["deleted"]) for i in feed["items"]] == [(2, True)]
    # If-Match: <tombstone version> revives: deleted=false, payload set, version+1, new changeSeq
    r = put(client, device, url, fixture_bytes(name), **{"If-Match": "2"})
    assert r.status_code == 200 and r.json() == {"version": 3, "changeSeq": 3}
    item = client.get("/api/v1/changes?since=2", headers=device).json()["items"][0]
    assert item["deleted"] is False and item["version"] == 3
    assert item["payload"] == json.loads(fixture_bytes(name))
    with ctx.db.read() as conn:
        assert conn.execute("SELECT payload FROM records").fetchone()[0] == fixture_bytes(name)
    # a revived record can be deleted again; DELETE on that tombstone is idempotent
    assert client.delete(url, headers={**device, "If-Match": "3"}).json() == {"version": 4, "changeSeq": 4}
    assert client.delete(url, headers={**device, "If-Match": "*"}).json() == {"version": 4, "changeSeq": 4}
    assert client.delete(url, headers={**device, "If-Match": "1"}).json() == {"version": 4, "changeSeq": 4}


def test_profile_round_trip(client, device):
    create(client, device, PROFILE_URL, fixture_bytes("profile.json"))
    item = client.get("/api/v1/changes", headers=device).json()["items"][0]
    assert item["key"] == "profile" and item["payload"]["settings"]["speechRate"] == 0.5


def test_changes_paging(client, device):
    keys = [f"2026-12-{d:02d}" for d in range(1, 8)]
    for k in keys:
        body = json.dumps({"date": f"{k}T07:00:00Z", "reason": "travel", "day": k}).encode()
        create(client, device, f"/api/v1/records/postponement/{k}", body)
    page = client.get("/api/v1/changes?since=0&limit=3", headers=device).json()
    assert [i["changeSeq"] for i in page["items"]] == [1, 2, 3]
    assert page["nextSince"] == 3 and page["hasMore"] is True
    page = client.get(f"/api/v1/changes?since={page['nextSince']}&limit=3", headers=device).json()
    assert [i["key"] for i in page["items"]] == keys[3:6] and page["hasMore"] is True
    page = client.get(f"/api/v1/changes?since={page['nextSince']}&limit=3", headers=device).json()
    assert [i["changeSeq"] for i in page["items"]] == [7] and page["hasMore"] is False and page["nextSince"] == 7
    empty = client.get("/api/v1/changes?since=7", headers=device).json()
    assert empty == {"items": [], "nextSince": 7, "hasMore": False}
    # an update moves the record to the end of the feed
    r = put(client, device, f"/api/v1/records/postponement/{keys[0]}",
            json.dumps({"date": "2026-12-01T08:00:00Z", "reason": "illness", "day": keys[0]}).encode(),
            **{"If-Match": "1"})
    assert r.json()["changeSeq"] == 8
    page = client.get("/api/v1/changes?since=7", headers=device).json()
    assert [(i["key"], i["version"]) for i in page["items"]] == [(keys[0], 2)]
    assert len(client.get("/api/v1/changes", headers=device).json()["items"]) == 7  # one row per key
    assert client.get("/api/v1/changes?limit=0", headers=device).status_code == 422
    assert client.get("/api/v1/changes?since=-1", headers=device).status_code == 422


def test_body_limit(client, device):
    big = b"{" + b" " * (4 * 1024 * 1024) + b"}"
    r = put(client, device, S_URL, big, **{"If-None-Match": "*"})
    assert r.status_code == 413
