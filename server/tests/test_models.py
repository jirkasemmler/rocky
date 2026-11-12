"""Catalog validation (mirror of RockyCore Catalog.validate()) and contract decoding of the
fixtures written by the Swift encoder."""

from __future__ import annotations

import copy
import json

import pytest

from app.models import (
    CatalogBody,
    Exercise,
    PostponementPayload,
    ProfilePayload,
    SessionPayload,
    text_length,
    validate_catalog,
)
from app.records import validate_payload
from app.timeutil import fmt, parse_swift_date

from .conftest import SEED, fixture_bytes


@pytest.fixture
def seed() -> dict:
    return json.loads(SEED.read_bytes())


def errors_for(data: dict) -> list[str]:
    return validate_catalog(CatalogBody.model_validate(data))


def test_seed_is_valid_and_round_trips(seed):
    body = CatalogBody.model_validate(seed)
    assert validate_catalog(body) == []
    assert seed["revision"] == 1
    wire = body.wire(1)
    # Every seed exercise survives unchanged (plus the explicit archived flag).
    for original, out in zip(seed["exercises"], wire["exercises"], strict=True):
        assert {**original, "archived": False} == out
    assert wire["workouts"] == seed["workouts"]
    by_id = {e["id"]: e for e in seed["exercises"]}
    assert by_id["reverse-lunge"]["switchesSideMidway"] is False
    assert by_id["dead-bug"]["switchesSideMidway"] is False


def mutate(seed, fn):
    data = copy.deepcopy(seed)
    fn(data)
    return errors_for(data)


@pytest.mark.parametrize(
    "fn, expected",
    [
        (lambda d: d["exercises"][0].update(id="Bad_ID"), "exercise Bad_ID: invalid id"),
        (lambda d: d["exercises"][0].update(id="a"), "exercise a: invalid id"),
        (lambda d: d["exercises"][1].update(id="squat"), "exercise squat: duplicate id"),
        (lambda d: d["exercises"][0].update(name=""), "exercise squat: name length"),
        (lambda d: d["exercises"][0].update(name="x" * 61), "exercise squat: name length"),
        (lambda d: d["exercises"][0].update(techniqueTip="x" * 201), "exercise squat: tip too long"),
        (lambda d: d["exercises"][0].update(instructions="x" * 2001), "exercise squat: instructions too long"),
        (lambda d: d["exercises"][0].update(target={"reps": {"min": 0, "max": 5}}), "exercise squat: reps range"),
        (lambda d: d["exercises"][0].update(target={"reps": {"min": 10, "max": 101}}), "exercise squat: reps range"),
        (lambda d: d["exercises"][0].update(target={"reps": {"min": 12, "max": 10}}), "exercise squat: reps range"),
        (lambda d: d["exercises"][3].update(target={"time": {"minSeconds": 4, "maxSeconds": 30}}),
         "exercise plank: time range"),
        (lambda d: d["exercises"][3].update(target={"time": {"minSeconds": 30, "maxSeconds": 301}}),
         "exercise plank: time range"),
        (lambda d: d["exercises"][3].update(target={"time": {"minSeconds": 50, "maxSeconds": 40}}),
         "exercise plank: time range"),
        (lambda d: d["exercises"][0].update(switchesSideMidway=True), "exercise squat: side switch without perSide"),
        (lambda d: d["workouts"].pop(2), "workout C: missing"),
        (lambda d: d["workouts"][0].update(exerciseIDs=[]), "workout A: 1–8 exercises"),
        (lambda d: d["workouts"][0].update(exerciseIDs=[e["id"] for e in d["exercises"][:9]]),
         "workout A: 1–8 exercises"),
        (lambda d: d["workouts"][0].update(exerciseIDs=["squat", "squat"]), "workout A: duplicates"),
        (lambda d: d["workouts"][0].update(exerciseIDs=["nope"]), "workout A: unknown exercise nope"),
        (lambda d: d["exercises"][0].update(archived=True), "workout A: archived exercise squat"),
        (lambda d: d["workouts"][0].update(name=""), "workout A: name length"),
        (lambda d: d.update(warmUpDescription=""), "warmUpDescription: length"),
        (lambda d: d.update(stretchDescription="x" * 501), "stretchDescription: length"),
    ],
)
def test_validation_rules(seed, fn, expected):
    assert expected in mutate(seed, fn)


def test_validation_boundaries_are_inclusive(seed):
    def fn(d):
        d["exercises"][0].update(name="x" * 60, techniqueTip="x" * 200, instructions="x" * 2000,
                                 target={"reps": {"min": 1, "max": 100}})
        d["exercises"][3].update(target={"time": {"minSeconds": 5, "maxSeconds": 300}})
        d["warmUpDescription"] = "x" * 500
        d["workouts"][0]["exerciseIDs"] = [e["id"] for e in d["exercises"][:8]]

    assert mutate(seed, fn) == []


def test_lengths_count_characters_not_bytes():
    assert text_length("Dřepy s činkami") == 15
    assert text_length("Dřepy") == 5  # decomposed ř counts once
    assert text_length("👍🏽") == 2  # approximation: skin-tone modifier counted (Swift says 1)


def test_target_shape():
    with pytest.raises(ValueError):
        Exercise.model_validate({"id": "x1", "name": "X", "techniqueTip": "", "equipment": "bodyweight",
                                 "target": {"reps": {"min": 1, "max": 2}, "time": {"minSeconds": 5, "maxSeconds": 6}}})
    with pytest.raises(ValueError):
        Exercise.model_validate({"id": "x1", "name": "X", "techniqueTip": "", "equipment": "bodyweight",
                                 "target": {"reps": {"min": 1, "max": 2, "extra": 1}}})
    e = Exercise.model_validate({"id": "x1", "name": "X", "techniqueTip": "", "equipment": "dumbbells",
                                 "perSide": True, "target": {"time": {"minSeconds": 5, "maxSeconds": 6}}})
    assert e.switchesSideMidway is True  # Swift default = perSide
    assert e.wire()["target"] == {"time": {"minSeconds": 5, "maxSeconds": 6}}
    assert "instructions" not in e.wire() and "imageAssetID" not in e.wire()


# ---------------------------------------------------------------- contract: Swift fixtures


def test_session_fixture_decodes():
    data = json.loads(fixture_bytes("session.json"))
    s = SessionPayload.model_validate(data)
    assert s.id == "6B0E4C8F-0F65-4C4B-9D0B-3B9C1C2B4F10"
    assert s.workoutID == "A" and s.kind == "catchUp" and s.completed
    assert s.workout["exercises"][0]["target"] == {"reps": {"max": 15, "min": 12}}
    assert validate_payload("session", s.id, fixture_bytes("session.json"))["id"] == s.id
    # embedded workout exercises are valid catalog exercises
    for ex in s.workout["exercises"]:
        Exercise.model_validate(ex)


def test_postponement_fixture_decodes():
    p = PostponementPayload.model_validate(json.loads(fixture_bytes("postponement.json")))
    assert p.day == "2026-11-13" and p.reason == "illness"


def test_profile_fixture_decodes():
    p = ProfilePayload.model_validate(json.loads(fixture_bytes("profile.json")))
    assert p.settings["intervals"]["stretchSeconds"] == 120
    assert parse_swift_date(p.planStart) == parse_swift_date("2026-11-01T23:00:00Z")


def test_swift_dates():
    d = parse_swift_date("2026-11-12T19:00:00Z")
    assert fmt(d) == "2026-11-12T19:00:00Z"
    assert parse_swift_date("2026-11-12T20:00:00+01:00") == d  # instants, not strings
    for bad in ("2026-11-12T19:00:00.123Z", "2026-11-12", "12.11.2026", 5):
        with pytest.raises(ValueError):
            parse_swift_date(bad)
