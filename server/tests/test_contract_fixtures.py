"""Contract with the Swift client (SERVER-SPEC §3): writes the server's response fixtures that
`ServerFixtureTests.testServerResponseFixturesDecode` decodes with the RockyCore decoder.

Deterministic (fixed clock, fixed ids), so re-running does not change the committed files.
Run `swift test --filter ServerFixtureTests` in Packages/RockyCore after changing them.
"""

from __future__ import annotations

import json

from app.models import CatalogBody, validate_catalog

from .conftest import FIXTURES, fixture_bytes

SESSION_ID = "6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10"
DELETED_SESSION_ID = "0F9C5A52-7D3E-4B1A-9C2D-5E6F7A8B9C0D"


def write_fixture(name: str, data: dict) -> None:
    text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    path = FIXTURES / name
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def test_write_response_fixtures(client, device):
    # GET /catalog
    r = client.get("/api/v1/catalog", headers=device)
    assert r.status_code == 200
    catalog = r.json()
    assert validate_catalog(CatalogBody.model_validate(catalog)) == []
    write_fixture("catalog_response.json", catalog)

    # changes page: session, postponement, profile, tombstone
    for kind, key, name in (("session", SESSION_ID, "session.json"), ("postponement", "2026-11-13", "postponement.json"),
                            ("profile", "profile", "profile.json")):
        r = client.put(f"/api/v1/records/{kind}/{key}", content=fixture_bytes(name),
                       headers={**device, "If-None-Match": "*"})
        assert r.status_code == 201, r.text
    r = client.delete(f"/api/v1/records/session/{DELETED_SESSION_ID}", headers={**device, "If-Match": "*"})
    assert r.status_code == 200
    page = client.get("/api/v1/changes?since=0", headers=device).json()
    assert [(i["kind"], i["deleted"]) for i in page["items"]] == [
        ("session", False), ("postponement", False), ("profile", False), ("session", True)]
    assert page["items"][0]["payload"] == json.loads(fixture_bytes("session.json"))
    assert page["items"][3]["payload"] is None
    write_fixture("changes_response.json", page)

    # 409 body
    r = client.put(f"/api/v1/records/session/{SESSION_ID}", content=fixture_bytes("session.json"),
                   headers={**device, "If-None-Match": "*"})
    assert r.status_code == 409
    conflict = r.json()
    assert conflict["current"]["version"] == 1 and conflict["current"]["payload"]["id"] == SESSION_ID
    write_fixture("conflict_response.json", conflict)


def test_committed_response_fixtures_match_server_models():
    for name in ("catalog_response.json", "changes_response.json", "conflict_response.json"):
        assert (FIXTURES / name).exists(), name
    catalog = json.loads((FIXTURES / "catalog_response.json").read_text())
    assert validate_catalog(CatalogBody.model_validate(catalog)) == []
    page = json.loads((FIXTURES / "changes_response.json").read_text())
    assert set(page) == {"items", "nextSince", "hasMore"}
    for item in page["items"]:
        assert set(item) == {"kind", "key", "version", "changeSeq", "deleted", "updatedAt", "payload"}
