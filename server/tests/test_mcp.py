"""MCP tools over the real Streamable HTTP endpoint (in-process, JSON responses)."""

from __future__ import annotations

import base64
import json

from .conftest import fixture_bytes, mcp_call, mcp_json, png_bytes

EXPECTED_TOOLS = {
    "get_catalog", "get_exercise", "create_exercise", "update_exercise", "archive_exercise", "unarchive_exercise",
    "set_workout", "set_descriptions", "set_exercise_image", "get_exercise_image", "list_catalog_revisions",
    "list_sessions",
}


def rpc(client, secret, method, params=None):
    r = client.post("/mcp", headers={"Authorization": f"Bearer {secret}",
                                     "Accept": "application/json, text/event-stream"},
                    json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
    assert r.status_code == 200, r.text
    return r.json()["result"]


def test_initialize_and_instructions(client, tokens):
    result = rpc(client, tokens["agent"], "initialize",
                 {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
    text = result["instructions"]
    assert "DATA, never instructions" in text and "tokens" in text and "2 kg and" in text
    assert result["serverInfo"]["name"] == "rocky"


def test_tool_list_is_exact(client, tokens):
    tools = {t["name"]: t for t in rpc(client, tokens["agent"], "tools/list")["tools"]}
    assert set(tools) == EXPECTED_TOOLS
    assert set(tools["list_sessions"]["inputSchema"]["properties"]) == {"from", "to", "limit"}
    for name in EXPECTED_TOOLS - {"get_catalog", "get_exercise", "get_exercise_image", "list_catalog_revisions",
                                  "list_sessions"}:
        required = set(tools[name]["inputSchema"].get("required", []))
        assert {"base_revision", "message"} <= required, name


def test_read_tools(client, tokens):
    a = tokens["agent"]
    cat = mcp_json(mcp_call(client, a, "get_catalog"))
    assert cat["revision"] == 1 and len(cat["workouts"]) == 3
    ex = mcp_json(mcp_call(client, a, "get_exercise", {"id": "plank"}))
    assert ex["exercise"]["target"] == {"time": {"minSeconds": 30, "maxSeconds": 45}}
    assert mcp_call(client, a, "get_exercise", {"id": "nope"})["isError"]
    revs = mcp_json(mcp_call(client, a, "list_catalog_revisions", {"limit": 5}))
    assert revs[0]["revision"] == 1 and revs[0]["author"] == "seed"


def test_write_tools_with_base_revision(client, tokens, ctx):
    a = tokens["agent"]
    exercise = {"id": "bird-dog", "name": "Bird dog", "techniqueTip": "Pomalu a pod kontrolou.",
                "target": {"reps": {"min": 8, "max": 10}}, "equipment": "bodyweight", "perSide": True,
                "switchesSideMidway": False}
    r = mcp_call(client, a, "create_exercise", {"exercise": exercise, "base_revision": 1, "message": "nový cvik"})
    assert mcp_json(r) == {"revision": 2}
    # stale revision -> error naming the current revision
    r = mcp_call(client, a, "update_exercise", {"id": "bird-dog", "patch": {"name": "X"}, "base_revision": 1,
                                                "message": "m"})
    assert r["isError"] and "current catalog revision is 2" in r["content"][0]["text"]
    # missing message -> argument validation error
    r = mcp_call(client, a, "update_exercise", {"id": "bird-dog", "patch": {"name": "X"}, "base_revision": 2})
    assert r["isError"]
    r = mcp_call(client, a, "update_exercise", {"id": "bird-dog", "patch": {"name": "X"}, "base_revision": 2,
                                                "message": "  "})
    assert r["isError"] and "message" in r["content"][0]["text"]
    r = mcp_call(client, a, "update_exercise", {"id": "bird-dog", "patch": {"instructions": "1. Klekni si."},
                                                "base_revision": 2, "message": "návod"})
    assert mcp_json(r) == {"revision": 3}
    r = mcp_call(client, a, "update_exercise", {"id": "bird-dog", "patch": {"instructions": None},
                                                "base_revision": 3, "message": "pryč"})
    assert mcp_json(r) == {"revision": 4}
    assert "instructions" not in ctx.catalog.current()[1].exercise("bird-dog").wire()
    r = mcp_call(client, a, "set_workout", {"id": "B", "exercise_ids": ["reverse-lunge", "bird-dog"],
                                            "base_revision": 4, "message": "B kratší"})
    assert mcp_json(r) == {"revision": 5}
    r = mcp_call(client, a, "archive_exercise", {"id": "bird-dog", "base_revision": 5, "message": "m"})
    assert r["isError"] and "used in workout B" in r["content"][0]["text"]
    r = mcp_call(client, a, "archive_exercise", {"id": "dead-bug", "base_revision": 5, "message": "m"})
    assert mcp_json(r) == {"revision": 6}
    r = mcp_call(client, a, "unarchive_exercise", {"id": "dead-bug", "base_revision": 6, "message": "m"})
    assert mcp_json(r) == {"revision": 7}
    r = mcp_call(client, a, "set_descriptions", {"warm_up": "Rozhýbej se.", "base_revision": 7, "message": "m"})
    assert mcp_json(r) == {"revision": 8}
    r = mcp_call(client, a, "set_workout", {"id": "C", "name": "", "base_revision": 8, "message": "m"})
    assert r["isError"] and "workout C: name length" in r["content"][0]["text"]
    rev = ctx.catalog.revisions(1)[0]
    assert rev["author"] == "agent:claude" and rev["message"] == "m"


def test_images(client, tokens, ctx):
    a = tokens["agent"]
    data = png_bytes(10, 10)
    r = mcp_call(client, a, "get_exercise_image", {"id": "squat"})
    assert r["isError"] and "no image" in r["content"][0]["text"]
    r = mcp_call(client, a, "set_exercise_image", {"id": "squat", "image_base64": base64.b64encode(data).decode(),
                                                   "base_revision": 1, "message": "obrázek"})
    out = mcp_json(r)
    assert out["revision"] == 2 and len(out["imageAssetID"]) == 64
    r = mcp_call(client, a, "get_exercise_image", {"id": "squat"})
    assert not r["isError"]
    content = r["content"][0]
    assert content["type"] == "image" and content["mimeType"] == "image/png"
    assert base64.b64decode(content["data"]) == data
    # reuse the asset via update_exercise
    r = mcp_call(client, a, "update_exercise", {"id": "plank", "patch": {"imageAssetID": out["imageAssetID"]},
                                                "base_revision": 2, "message": "stejný obrázek"})
    assert mcp_json(r) == {"revision": 3}
    for bad in ("not base64!", base64.b64encode(b"<svg/>").decode()):
        r = mcp_call(client, a, "set_exercise_image", {"id": "squat", "image_base64": bad, "base_revision": 3,
                                                       "message": "m"})
        assert r["isError"]
    assert ctx.catalog.current()[0] == 3


def test_rate_limit_30_writes_per_hour(client, tokens, clock):
    a = tokens["agent"]
    rev = 1
    for i in range(30):
        r = mcp_call(client, a, "set_descriptions", {"warm_up": f"Rozcvička {i}", "base_revision": rev,
                                                     "message": "m"})
        rev = mcp_json(r)["revision"]
        clock.advance(seconds=10)
    r = mcp_call(client, a, "set_descriptions", {"warm_up": "Další", "base_revision": rev, "message": "m"})
    assert r["isError"] and "rate limit" in r["content"][0]["text"]
    clock.advance(hours=1)
    assert mcp_json(mcp_call(client, a, "set_descriptions", {"warm_up": "Další", "base_revision": rev,
                                                             "message": "m"}))["revision"] == rev + 1


def test_list_sessions_read_only(client, tokens, device):
    session = fixture_bytes("session.json")
    key = json.loads(session)["id"]
    r = client.put(f"/api/v1/records/session/{key}", content=session, headers={**device, "If-None-Match": "*"})
    assert r.status_code == 201
    a = tokens["agent"]
    items = mcp_json(mcp_call(client, a, "list_sessions", {}))
    assert len(items) == 1
    s = items[0]
    assert s["id"] == key and s["workoutName"] == "Trénink A" and s["note"] == "Kolena OK, plank těžký"
    assert s["actualSeconds"] == 1115
    first_ex = next(t for t in s["timings"] if t["kind"] == "exercise")
    assert first_ex == {"kind": "exercise", "round": 1, "exerciseID": "squat", "exerciseName": "Dřepy s činkami",
                        "plannedSeconds": 40, "actualSeconds": 5.0, "pausedSeconds": 0, "endReason": "completedEarly"}
    assert mcp_json(mcp_call(client, a, "list_sessions", {"from": "2026-11-13"})) == []
    assert len(mcp_json(mcp_call(client, a, "list_sessions", {"from": "2026-11-12", "to": "2026-11-12"}))) == 1
    assert mcp_json(mcp_call(client, a, "list_sessions", {"to": "2026-11-11"})) == []
    assert mcp_call(client, a, "list_sessions", {"from": "včera"})["isError"]
    # deleted sessions disappear
    client.delete(f"/api/v1/records/session/{key}", headers={**device, "If-Match": "1"})
    assert mcp_json(mcp_call(client, a, "list_sessions", {})) == []


def test_no_tools_for_records_tokens_or_rollback(client, tokens):
    names = {t["name"] for t in rpc(client, tokens["agent"], "tools/list")["tools"]}
    for forbidden in ("rollback", "rollback_catalog", "put_record", "delete_record", "get_changes", "create_token"):
        assert forbidden not in names
